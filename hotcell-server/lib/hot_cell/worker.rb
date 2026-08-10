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
      @booted = {}
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
      ENV["HOME"] = slot.home

      while (dispatch = await_dispatch)
        serve(*dispatch)
      end

      exit! 0
    rescue Exception => error
      log.write "worker.crashed", slot: slot.number, error: error.class.name,
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
          line, received = connection.receive_message
          response = handle(line, received, timing) unless line.nil?
        rescue MessageError, AccessModeError => error
          response = refuse("invalid", error, timing)
        rescue NoMemoryError, Errno::ENOMEM, MemoryExhausted => error
          response = refuse(Codes::KILLED, error, timing, limit: Codes::MEMORY)
        rescue StandardError => error
          response = refuse("failed", error, timing)
        end

        deliver connection, response
        record response, timing
      ensure
        received.each(&:close)
        connection.close
        slot.remove_scratch
        report_idle response&.failure&.code
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

        convert operation, inputs, outputs, request.payload, timing
      end

      def convert(operation, inputs, outputs, payload, timing)
        timing.performing

        timing.measure(:staging_ms) { stage inputs, outputs } if operation.stage == :paths
        result = timing.measure(:convert_ms) { operation.new.perform(inputs, outputs, payload) }
        timing.measure(:writeback_ms) { outputs.each(&:post) }

        # Read before the scratch goes, so perform_ms measures performing and not the cleanup after it.
        Payload.validate! result, "result"
        response = Response.ok(result: result, timing: timing.to_h)

        # Before answering rather than after, so the window in which a sibling worker could read this
        # request's bytes off the shared tmpfs closes before the caller is told anything. Files are not
        # isolated between concurrent workers and cannot be, so the window's size is the whole control.
        slot.remove_scratch

        response
      rescue *operation.unreadable => error
        refuse "unreadable", error, timing
      end

      def wrap(request, received)
        unless received.size == request.descriptor_count
          raise MessageError, "#{request.op} wants #{request.descriptor_count} descriptors and " \
                              "#{received.size} arrived"
        end

        [ received.first(request.inputs).map { |io| Input.new(io) },
          received.last(request.outputs).map { |io| Output.new(io) } ]
      end

      def stage(inputs, outputs)
        scratch = slot.make_scratch
        inputs.each_with_index { |input, index| input.stage File.join(scratch, "input-#{index}") }
        outputs.each_with_index { |output, index| output.stage File.join(scratch, "output-#{index}") }
      end

      def boot(operation)
        return if @booted[operation]

        operation.before_worker_boot.each(&:call)
        @booted[operation] = true
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
        log.write "request.abandoned", slot: slot.number
      end

      def line_for(response)
        response.to_line
      rescue SerializationError, MessageError => error
        Response.failed(Failure.for("failed", error), timing: response.timing).to_line
      end

      def record(response, timing)
        return if response.nil?

        log.write "request", slot: slot.number, code: response.failure&.code || "ok",
                             terminal: response.failure&.terminal?, elapsed_ms: timing.elapsed_ms,
                             **response.timing
      end

      def refuse(code, detail, timing, limit: nil)
        Response.failed Failure.for(code, detail, limit: limit), timing: timing.to_h
      end
  end
end
