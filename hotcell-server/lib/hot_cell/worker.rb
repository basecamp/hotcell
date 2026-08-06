# frozen_string_literal: true

require "fileutils"

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
    def run
      configuration.limits.apply
      ENV["HOME"] = slot.home

      while (dispatch = await_dispatch)
        serve(*dispatch)
      end

      exit! 0
    rescue Exception => error # rubocop:disable Lint/RescueException
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
        started = Clock.now
        received = []
        response = nil

        begin
          line, received = connection.receive_message
          response = handle(line, received, queued_ms, started) unless line.nil?
        rescue MessageError, AccessModeError => error
          response = refuse("invalid", error, queued_ms, started)
        rescue NoMemoryError, Errno::ENOMEM, MemoryExhausted => error
          response = refuse(Codes::KILLED, error, queued_ms, started, limit: "memory")
        rescue StandardError => error
          response = refuse("failed", error, queued_ms, started)
        end

        deliver connection, response
        record response, started
      ensure
        received.each(&:close)
        connection.close
        remove_scratch
        report_idle response&.failure&.code
      end

      def handle(line, received, queued_ms, started)
        request = Request.parse(line)

        unless request.current_version?
          return refuse("protocol", "this cell speaks v#{PROTOCOL_VERSION} and the request is " \
                                    "v#{request.version}", queued_ms, started)
        end

        operation = Registry.lookup(request.op)
        return refuse("unsupported", "no operation named #{request.op.inspect}", queued_ms, started) if operation.nil?

        inputs, outputs = wrap(request, received)
        boot operation
        narrow operation
        report_deadline operation

        convert operation, inputs, outputs, request.payload, queued_ms
      end

      def convert(operation, inputs, outputs, payload, queued_ms)
        timing = { queued_ms: queued_ms }
        began = Clock.now

        timing[:staging_ms] = measure { stage inputs, outputs } if operation.stage == :paths
        result = nil
        timing[:convert_ms] = measure { result = operation.new.perform(inputs, outputs, payload) }
        timing[:writeback_ms] = measure { outputs.each(&:post) }
        timing[:perform_ms] = Clock.ms_since(began)

        # Before answering rather than after, so the window in which a sibling worker could read this
        # request's bytes off the shared tmpfs closes before the caller is told anything. Files are not
        # isolated between concurrent workers and cannot be, so the window's size is the whole control.
        remove_scratch

        Payload.validate! result, "result"
        Response.ok result: result, timing: timing
      rescue *operation.unreadable => error
        refuse "unreadable", error, queued_ms, began
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
        scratch = make_scratch
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
        Response.failed(verdict("failed", error), timing: response.timing).to_line
      end

      def record(response, started)
        return if response.nil?

        log.write "request", slot: slot.number, code: response.failure&.code || "ok",
                             terminal: response.failure&.terminal?, elapsed_ms: Clock.ms_since(started),
                             **response.timing
      end

      def refuse(code, detail, queued_ms, since, limit: nil)
        Response.failed verdict(code, detail, limit: limit),
                        timing: { queued_ms: queued_ms, perform_ms: Clock.ms_since(since) }
      end

      def verdict(code, detail, limit: nil)
        if detail.is_a?(Exception)
          Failure.new code: code, limit: limit, error_class: detail.class.name, message: detail.message
        else
          Failure.new code: code, limit: limit, message: detail
        end
      end

      def make_scratch
        FileUtils.mkdir_p slot.scratch, mode: 0o700
        slot.scratch
      end

      def remove_scratch
        FileUtils.remove_entry slot.scratch if Dir.exist?(slot.scratch)
      rescue SystemCallError
        nil
      end

      def measure
        at = Clock.now
        yield
        Clock.ms_since at
      end
  end
end
