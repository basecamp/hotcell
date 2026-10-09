# frozen_string_literal: true

require "json"
require "socket"

module HotCell
  # hotcell-client defines Client as a class as well, so this opens it whether or not that gem is loaded.
  class Client
    # A client for an application that cannot run hotcell-client: one file, the standard library only, and
    # legacy Ruby versions. It speaks the same v1 wire protocol to the same work socket.
    #
    #   client = HotCell::Client::Legacy.new("/run/hotcell/images/work.sock", timeout: 30, group: 10001)
    #   client.perform "images.transform", [ input ], [ output ], "format" => "png"
    #
    # Written for Ruby 1.9.3, so it uses no keyword arguments, `&.`, `String#b` or `IO#wait_readable`.
    class Legacy
      VERSION = "1.1.0"

      PROTOCOL_VERSION = 1
      MAX_RESPONSE_BYTES = 65_536
      MAX_FIELD_BYTES = 512

      # The fields of a failure on the wire. Anything else a cell sends is dropped rather than passed on unscrubbed.
      FAILURE_FIELDS = [ :code, :cause, :signal, :class, :message, :stderr ].freeze
      CHUNK_BYTES = 4096

      # The same modes hotcell-client sets, for the same reason: the cell reopens a descriptor by name as
      # `/dev/fd/N`, which the kernel checks against the cell's uid and group rather than ours.
      INPUT_MODE = 0o640
      OUTPUT_MODE = 0o620

      # A cell's verdict on a request that did not succeed, with the readers of hotcell-core's HotCell::Failure.
      class Failure
        attr_reader :code, :cause, :signal, :error_class, :message, :stderr

        def initialize(fields)
          @permanent = fields[:permanent]
          @code = fields[:code].to_s
          @cause = fields[:cause]
          @signal = fields[:signal]
          @error_class = fields[:class]
          @message = fields[:message]
          @stderr = fields[:stderr]
        end

        def permanent?
          @permanent
        end

        def to_h
          { code: code, permanent: permanent?, cause: cause, signal: signal, class: error_class, message: message,
            stderr: stderr }.reject { |_key, value| value.nil? }
        end

        # A cell that sent no code gets none in the message, rather than a leading ": ".
        def to_s
          [ (code unless code.empty?), cause, error_class, message ].compact.join(": ")
        end

        # Included in both failure classes, so `rescue Failure::Exception` catches either and
        # `hot_cell_failure` reads the failure, as with hotcell-client's HotCell::Failure::Exception. The
        # classes share no superclass, so rescuing one by name never catches the other: a permanent failure
        # may be written down against a file forever, and a transient one must be retried.
        module Exception
          attr_reader :hot_cell_failure

          def initialize(failure)
            @hot_cell_failure = failure
            super(failure.to_s)
          end
        end
      end

      class PermanentFailure < StandardError
        include Failure::Exception
      end

      class TransientFailure < StandardError
        include Failure::Exception
      end

      class Timeout < StandardError; end
      private_constant :Timeout

      attr_reader :socket_path, :timeout, :group

      # `timeout` is one deadline in seconds across the connect, the send and the read. `group` is the cell's
      # gid, which every input and output is given before the request goes out; leave it unset only where the
      # application and the cell run as one user.
      def initialize(socket_path, options = {})
        @socket_path = socket_path
        @timeout = options.fetch(:timeout, 30)
        @group = options[:group]
      end

      # Returns the operation's result, a Hash with String keys. Raises PermanentFailure or TransientFailure
      # according to the `permanent` flag on the cell's answer; a failure with no answer at all is transient.
      def perform(operation, inputs, outputs, payload = {})
        inputs = [ inputs ] unless inputs.is_a?(Array)
        outputs = [ outputs ] unless outputs.is_a?(Array)

        # Outside the rescue below, because a file this process cannot chown is the caller's bug, and an
        # application whose own transient class descends from SystemCallError would retry it forever.
        share inputs, INPUT_MODE
        share outputs, OUTPUT_MODE

        line = JSON.generate("v" => PROTOCOL_VERSION, "op" => operation.to_s, "inputs" => inputs.size,
                             "outputs" => outputs.size, "payload" => payload) + "\n"

        answer = exchange(line, inputs + outputs)
        return answer["result"] if answer["ok"]

        # Built rather than passed to raise, because Ruby 2.x reads a trailing Hash given to raise as its options
        # and takes `cause` out of it.
        failure = Failure.new(sanitize(answer["error"]))
        raise (failure.permanent? ? PermanentFailure : TransientFailure).new(failure)
      end

      private
        def share(ios, mode)
          return if group.nil?

          ios.each do |io|
            io.chown nil, group
            io.chmod mode
          end
        end

        def exchange(line, descriptors)
          deadline = now + timeout
          socket = Socket.new(:UNIX, :STREAM)
          connect socket, deadline
          deliver socket, line, descriptors, deadline
          response = receive(socket, deadline)
          return unavailable("the connection closed with no response, so the cell's supervisor is gone") if response.nil?

          parse response
        rescue Timeout
          transient "timeout", "the cell did not answer within #{timeout}s"
        rescue SystemCallError, IOError => error
          unavailable "#{error.class}: #{error.message}"
        ensure
          socket.close if socket && !socket.closed?
        end

        # Non-blocking, because a blocking connect to a Unix socket whose backlog is full waits in the kernel
        # with no deadline, and a supervisor that has stopped calling `accept` leaves it full. Linux answers a
        # non-blocking connect to that backlog with EAGAIN and leaves the socket unconnected, so it is retried
        # rather than waited on: an unconnected Unix socket is always writable, and `select` would not wait.
        def connect(socket, deadline)
          socket.connect_nonblock Socket.sockaddr_un(socket_path)
        rescue Errno::EAGAIN
          remaining = deadline - now
          raise Timeout unless remaining > 0

          sleep [ 0.01, remaining ].min
          retry
        end

        # The descriptors ride the first sendmsg and the rest of the line follows as ordinary writes, because a
        # stream socket does not promise that one sendmsg sends all of it, and ancillary data must go exactly
        # once. A request with no descriptors sends no ancillary data at all, as hotcell-core does.
        #
        # A full cell answers `capacity` and closes the connection without reading the request, so the send can
        # fail while the answer is already waiting. A failed send is ignored, and the read decides.
        def deliver(socket, line, descriptors, deadline)
          controls = descriptors.empty? ? [] : [ Socket::AncillaryData.unix_rights(*descriptors.map { |io| io.to_io }) ]
          sent = waiting(socket, :writable, deadline) { socket.sendmsg_nonblock(line, 0, nil, *controls) }

          until sent == line.bytesize
            sent += waiting(socket, :writable, deadline) { socket.write_nonblock(line.byteslice(sent..-1)) }
          end
        rescue Errno::EPIPE, Errno::ECONNRESET
          nil
        end

        # Returns nil when the peer closed without sending anything. The deadline covers the whole line rather
        # than each read, so a peer that sends one byte and stops cannot hold the caller past it.
        def receive(socket, deadline)
          buffer = String.new

          until buffer.end_with?("\n")
            chunk = begin
              waiting(socket, :readable, deadline) { socket.read_nonblock(CHUNK_BYTES) }
            rescue EOFError
              return nil if buffer.empty?

              raise IOError, "the cell's answer ended after #{buffer.bytesize} bytes with no newline"
            end

            buffer << chunk
            if buffer.bytesize > MAX_RESPONSE_BYTES
              raise IOError, "the cell's answer passed #{MAX_RESPONSE_BYTES} bytes with no newline"
            end
          end

          buffer.force_encoding Encoding::UTF_8
        end

        def waiting(socket, direction, deadline)
          yield
        rescue IO::WaitReadable, IO::WaitWritable
          remaining = deadline - now
          raise Timeout unless remaining > 0

          readers, writers = direction == :readable ? [ [ socket ], nil ] : [ nil, [ socket ] ]
          raise Timeout unless IO.select(readers, writers, nil, remaining)

          retry
        end

        # `ok` must be the boolean it says it is, because Ruby would read `"false"`, `0` and `[]` as success, and
        # a garbled answer would become an `ok` carrying no result.
        #
        # String keys, because Ruby before 2.2 never frees a Symbol: symbolizing the keys a cell chooses would let a
        # compromised cell grow this process's memory with every answer.
        def parse(line)
          answer = begin
            JSON.parse(line)
          rescue StandardError => error
            return unavailable("the cell's answer is not JSON: #{error.class}")
          end

          valid = answer.is_a?(Hash) &&
            ((answer["ok"] == true && answer["result"].is_a?(Hash)) ||
             (answer["ok"] == false && answer["error"].is_a?(Hash)))
          valid ? answer : unavailable("the cell's answer is not a v#{PROTOCOL_VERSION} response")
        end

        # A failure's text comes from a process that has just parsed a hostile file, and JSON.parse is not a
        # filter: it passes bytes that are not UTF-8 straight through, and a String holding them makes a regex
        # raise ArgumentError and a log line raise Encoding::CompatibilityError. So every String field is capped
        # and scrubbed, as hotcell-core's Failure does. `stderr` keeps its tail, where the fatal line is.
        def sanitize(error)
          sanitized = { permanent: error["permanent"] == true }
          FAILURE_FIELDS.each do |key|
            value = error[key.to_s]
            sanitized[key] = scrub(value.to_s, key == :stderr) unless value.nil?
          end
          sanitized
        end

        # Through UTF-16, because Ruby before 2.1 has no String#scrub and skips an encode from UTF-8 to UTF-8.
        def scrub(text, keep_tail)
          text = text.dup.force_encoding(Encoding::UTF_8)
          if text.bytesize > MAX_FIELD_BYTES
            text = keep_tail ? text.byteslice(-MAX_FIELD_BYTES, MAX_FIELD_BYTES) : text.byteslice(0, MAX_FIELD_BYTES)
          end
          return text if text.valid_encoding?

          text.encode(Encoding::UTF_16LE, invalid: :replace, undef: :replace, replace: "").encode(Encoding::UTF_8)
        end

        def unavailable(message)
          transient "unavailable", message
        end

        def transient(code, message)
          { "ok" => false, "error" => { "code" => code, "permanent" => false, "message" => message } }
        end

        # Monotonic where the Ruby has it (2.1 and later), so a clock stepped by NTP cannot stretch a deadline.
        if defined?(Process::CLOCK_MONOTONIC)
          def now
            Process.clock_gettime Process::CLOCK_MONOTONIC
          end
        else
          def now
            Time.now.to_f
          end
        end
    end
  end
end
