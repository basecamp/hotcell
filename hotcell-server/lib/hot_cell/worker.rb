# frozen_string_literal: true

module HotCell
  # Every untrusted byte is touched here and nowhere else.
  #
  # The worker applies the cell's limits before it touches the socket, narrows to the operation's limits
  # before it reads an untrusted byte, and calls exit! on the way out so that no finalizer and no library
  # teardown ever runs. Limits go on in two passes because the worker has to parse the request before it
  # can know which operation's limits to use, and parsing is the first thing it does with
  # attacker-influenced bytes — so the cell's maximums go on at a point that needs no parsing at all.
  #
  # There is deliberately no shutdown hook. The exit! is the point, and a hook would invite cleanup code
  # that is then skipped.
  class Worker
    DISPATCH_BYTES = 1024

    def initialize(slot:, configuration:, control:, log:)
      @slot = slot
      @configuration = configuration
      @control = control
      @log = log
      @booted = nil
      @effective = {}
    end

    # exit! rather than exit, so that no finalizer and no library teardown ever runs. There is deliberately no
    # shutdown hook: the exit! is the point, and a hook would invite cleanup code that is then skipped.
    #
    # A non-zero status for anything unexpected, because the supervisor holds the connection and is the only
    # thing that can answer for a worker that died mid-request. Exiting zero here would leave a caller reading
    # a closed socket with no verdict at all.
    #
    # **The one deliberate `rescue Exception` in this repository.** Not for the exit status — Ruby's own handler
    # would also exit non-zero — but for Failure.sanitize. Left to Ruby, a NoMemoryError or a SystemStackError
    # prints its message and backtrace to stderr unsanitized, and in this process that message can carry bytes
    # derived from a hostile file. sanitize forces UTF-8, scrubs invalid sequences and truncates; stderr is the
    # one path out of a cell that would otherwise skip it, which is how an unscrubbed byte sequence reaches a
    # log row and poisons it.
    #
    # It swallows nothing: `exit! 1` runs whatever was caught.
    def run
      configuration.limits.apply

      while (dispatch = await_dispatch)
        serve(*dispatch)
      end

      exit! 0
    rescue Exception => error
      log.write "worker.crashed", pid: Process.pid, slot: slot.number, error: error.class.name,
                                  message: Failure.sanitize(error.message)
      exit! 1
    end

    private
      attr_reader :slot, :configuration, :control, :log

      # Returns [connection, queued_ms], or nil once the supervisor has retired this worker by closing the
      # control socket. The connection arrives as a descriptor: the supervisor accepted it and never
      # called recvmsg, so the caller's own descriptors are still queued on it and this worker's recvmsg
      # is what installs them.
      def await_dispatch
        line, descriptors = control.receive_message(limit: DISPATCH_BYTES)
        return nil if line.nil?

        socket = descriptors.first
        return nil if socket.nil?

        [ Connection.new(socket), Payload.parse(line).fetch(:queued_ms, 0) ]
      end

      def serve(connection, queued_ms)
        timing = Timing.new(queued_ms)
        received = []
        response = nil

        begin
          # Before the request rather than at boot, and one directory rather than two. A tool reads its
          # configuration from $HOME and that configuration is executable, so a home that outlived the
          # request let one compromised conversion reconfigure every later one on this slot. adr/0003.
          #
          # Inside the begin, because a home that cannot be created is a broken deployment and answers
          # `failed`, which is transient. Outside it the raise skipped every response path and reached
          # `run`, which exits the worker — after this ensure had already reported idle `"ok"`, counting a
          # success for a request that never ran.
          ENV["HOME"] = slot.make_home

          line, received = connection.receive_message
          response = if line.nil?
            # The caller closed before sending a request. Transient, so it is never written against a blob,
            # and named rather than left nil — a nil response reported idle `"ok"`, counting a success nobody
            # received.
            refuse("unavailable", "the connection closed before a request arrived", timing)
          else
            handle(line, received, timing)
          end
        rescue MessageError, AccessModeError => error
          response = refuse("invalid", error, timing)
        # NoMemoryError and MemoryExhausted are this input driving this worker past its own memory, which is
        # permanent. Errno::ENOMEM is deliberately not here: a fork or mmap that cannot get memory is host
        # pressure the input did not cause, so it falls through to `failed` with EMFILE and ENOSPC and is
        # transient. Adding it back would condemn a blob for the cell's own bad moment.
        rescue NoMemoryError, MemoryExhausted => error
          response = refuse(Codes::KILLED, error, timing, cause: Codes::MEMORY)
        rescue StandardError => error
          response = refuse("failed", error, timing)
        end

        deliver connection, response
        record response, timing
      ensure
        received.each(&:close)
        connection.close
        home = slot.home
        swept = slot.remove_home

        # After the answer and before reporting idle, which is the only window where this costs nobody. How
        # long it takes is chosen by whatever filled the directory, so it must not run where somebody is
        # waiting: not in the supervisor, whose loop enforces every other request's deadline, and not during
        # staging, where it would spend the next request's deadline on the previous request's mess. Here the
        # caller already has its response, and `report_idle` is what makes this worker available — so the
        # supervisor will not dispatch into a worker that is still sweeping.
        report_uncleaned home unless swept
        report_unswept unless slot.sweep
        report_idle response&.failure&.code
      end

      # A removal that failed is the one thing here nobody else can see. The bytes stay on the shared tmpfs
      # after the caller has been told the request is over, and a sibling worker can cause it by writing into
      # the tree while remove_entry walks it. It cannot raise from an ensure, so it says so instead. One line
      # per request, from the ensure, because that is the attempt that knows the final state.
      def report_uncleaned(home)
        log.write "slot.uncleaned", pid: Process.pid, slot: slot.number, home: home
      end

      # The other half of the same fact. A sweep removes what the supervisor renamed out of the way after a
      # killed request, and its failure was the one cleanup outcome nobody said anything about — so a slot
      # accumulating one tree per request looked exactly like a slot that was clean.
      def report_unswept
        log.write "slot.unswept", pid: Process.pid, slot: slot.number, home: slot.directory
      end

      def handle(line, received, timing)
        request = Request.parse(line)

        unless request.current_version?
          return refuse("protocol", request.version_mismatch, timing)
        end

        operation = Registry.lookup(request.op)
        return refuse("unsupported", "no operation named #{request.op.inspect}", timing) if operation.nil?

        inputs, outputs = wrap(request, received)
        boot operation
        narrow operation
        report_deadline operation

        perform operation, inputs, outputs, request.payload, timing
      end

      def perform(operation, inputs, outputs, payload, timing)
        timing.performing

        result = timing.measure(:operation_ms) { operation.new.perform(inputs, outputs, **payload) }
        written = timing.measure(:writeback_ms) { outputs.map(&:post) }

        return unwritten(outputs, written, timing) if written.any?(&:zero?)

        # Read before the scratch goes, so perform_ms measures performing and not the cleanup after it.
        Payload.validate! result, "result"
        response = Response.ok(result: result, timing: timing.to_h)

        # Before answering rather than after, so the window in which a sibling worker could read this
        # request's bytes off the shared tmpfs closes before the caller is told anything. Files are not
        # isolated between concurrent workers and cannot be, so the window's size is the whole control.
        # Not reported here. The ensure below runs after every path through this method and tries again, so
        # it is the one that knows whether the directory is still there when the request is over.
        slot.remove_home

        response
      rescue *operation.unreadable => error
        refuse "unreadable", error, timing
      end

      # `post` returns what each output received and the worker used to throw all of it away, leaving the
      # client to check the total size of the outputs it had handed over. A total hides the case the
      # multiple-output API exists for: writing the first and skipping the second is a positive total and
      # reads as success. This is the side that knows which one is empty, so it is the side that says so.
      #
      # Transient, for the reason the client's own check is: the commonest way to write nothing is a full
      # tmpfs, and a full filesystem must never be recorded as a verdict on the document.
      def unwritten(outputs, written, timing)
        empty = written.each_index.select { |index| written[index].zero? }

        refuse "unavailable",
               "#{empty.size} of #{outputs.size} outputs received no bytes (#{empty.join(", ")})",
               timing
      end

      def wrap(request, received)
        unless received.size == request.descriptor_count
          raise MessageError, "#{request.op} wants #{request.descriptor_count} descriptors and " \
                              "#{received.size} arrived"
        end

        [ received.first(request.inputs).map.with_index { |io, index| Input.new(io, scratch: scratch("input-#{index}")) },
          received.last(request.outputs).map.with_index { |io, index| Output.new(io, scratch: scratch("output-#{index}")) } ]
      end

      # A name inside this request's own `$HOME`, which `serve` has already created. Deferred rather than
      # computed up front because a descriptor only asks when the operation reaches for a path, and an
      # operation that reads its descriptors directly never asks at all.
      def scratch(name)
        -> { File.join(slot.home, name) }
      end

      # Tracks the last operation configured for rather than every one ever seen. Above `max_requests_per_worker: 1`
      # a worker can serve A, then B, then A — and a set-shaped memo skipped A's hooks the second time, leaving it
      # running under whatever B had set the shared library to. What these hooks configure is global and singular,
      # so the question is not "has this ever run" but "is this what the library is set up for".
      def boot(operation)
        return if @booted == operation

        operation.before_worker_boot.each(&:call)
        @booted = operation
      end

      def narrow(operation)
        effective(operation).apply ceiling: configuration.limits
      end

      # The supervisor enforces the deadline and never reads a request, so it cannot know that this
      # operation asked for less than the cell's maximum. The worker is the only thing that knows, and it
      # says so before it touches an untrusted byte.
      def report_deadline(operation)
        tell deadline: effective(operation).deadline
      end

      def report_idle(code)
        tell idle: true, code: code || "ok"
      end

      def tell(**message)
        control.write_line JSON.generate(message) << "\n"
      rescue SystemCallError, IOError
        nil
      end

      def effective(operation)
        @effective[operation] ||= operation.limits.clamped_to(configuration.limits)
      end

      def deliver(connection, response)
        return if response.nil?

        connection.write_line line_for(response)
      rescue SystemCallError, IOError
        log.write "request.abandoned", pid: Process.pid, slot: slot.number
      end

      def line_for(response)
        response.to_line
      rescue SerializationError, MessageError => error
        Response.failed(Failure.for("failed", error), timing: response.timing).to_line
      end

      def record(response, timing)
        return if response.nil?

        log.write "request", pid: Process.pid, slot: slot.number, code: response.failure&.code || "ok",
                             permanent: response.failure&.permanent?,
                             outcome: response.failure ? "failure" : "success",
                             duration_ms: timing.elapsed_ms, timing: response.timing
      end

      def refuse(code, detail, timing, cause: nil)
        Response.failed Failure.for(code, detail, cause: cause), timing: timing.to_h
      end
  end
end
