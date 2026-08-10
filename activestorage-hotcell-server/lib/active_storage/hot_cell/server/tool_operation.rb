# frozen_string_literal: true

require "hot_cell/server"

module ActiveStorage
  module HotCell
    module Server
      # Everything that hands the untrusted bytes to an exec'd tool rather than parsing them here.
      #
      # A malicious input executes inside a child that dies at the end of the conversion, and this worker only
      # copies bytes, spawns, and reads an exit status. That is worth knowing when reading these operations,
      # and it is worth being careful about when changing them: reading a tool's output with an
      # in-process library — to put dimensions in the result, say — or parsing its stdout brings bytes a
      # hostile input produced back into this worker. Neither happens here.
      class ToolOperation < ::HotCell::Operation
        abstract_operation

        # A tool that exits non-zero on a document it cannot read is the commonest failure on this path, and
        # it is the input's fault rather than the operation's.
        class UnreadableDocument < ::HotCell::UnreadableInput; end

        unreadable UnreadableDocument

        private
          # Runs the tool with unsetenv_others and a written environment, and turns a non-zero exit into
          # `unreadable`. The tool's own stderr is the only useful diagnostic, and it is attacker-influenced,
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

          # An empty output file means the tool said it succeeded and produced nothing, which the client
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
end
