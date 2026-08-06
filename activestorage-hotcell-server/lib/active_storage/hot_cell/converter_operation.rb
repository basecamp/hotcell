# frozen_string_literal: true

require "hot_cell/server"

module ActiveStorage
  module HotCell
    # Everything that hands the untrusted bytes to an exec'd converter rather than parsing them here.
    #
    # That is what `untrusted_input :subprocess` claims, and the claim is about this code rather than about the
    # converter: a malicious input executes inside a child that dies at the end of the conversion, and this
    # worker only copies bytes, spawns, and reads an exit status. Recycling such a worker buys nothing, because
    # it was never exposed.
    #
    # The claim is easy to break later, and there are exactly two ways. Reading the converter's *output* with an
    # in-process library — to put dimensions in the result, say — parses bytes a converter just produced from a
    # hostile input, in this worker. So does parsing its stdout. Neither happens here, and the suite asserts the
    # declarations rather than trusting these paragraphs.
    class ConverterOperation < ::HotCell::Operation
      untrusted_input :subprocess

      # A converter that exits non-zero on a document it cannot read is the commonest failure on this path, and
      # it is the input's fault rather than the operation's.
      class UnreadableDocument < ::HotCell::UnreadableInput; end

      unreadable UnreadableDocument

      private
        # Runs the converter with unsetenv_others and a written environment, and turns a non-zero exit into
        # `unreadable`. The converter's own stderr is the only useful diagnostic, and it is attacker-influenced,
        # so it is capped and scrubbed on its way onto the wire like any other error message.
        def run!(*command)
          converted = convert(*command)
          return converted if converted.ok?

          raise UnreadableDocument, "#{command.first} exited #{converted.status.exitstatus}: " \
                                    "#{converted.err.to_s.strip[0, 200]}"
        end

        def refuse!(message)
          raise ::HotCell::MessageError, message
        end

        # An empty output file means the converter said it succeeded and produced nothing, which the client
        # would otherwise have to catch as zero bytes on a successful response.
        def produced!(path, command)
          bytes = File.exist?(path) ? File.size(path) : 0
          raise UnreadableDocument, "#{command} wrote nothing" if bytes.zero?

          bytes
        end

        def positive_integer!(payload, key, default, maximum)
          value = payload.fetch(key, default)
          return value if value.is_a?(Integer) && value.positive? && value <= maximum

          refuse! "#{key} #{value.inspect} must be an integer between 1 and #{maximum}"
        end
    end
  end
end
