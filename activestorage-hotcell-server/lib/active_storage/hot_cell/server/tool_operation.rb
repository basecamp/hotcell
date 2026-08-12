# frozen_string_literal: true

require "active_storage/hot_cell/server/operation"

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
      class ToolOperation < Operation
        abstract_operation

        # A tool that exits non-zero on a document it cannot read is the commonest failure on this path, and
        # it is the input's fault rather than the operation's. No `unreadable` declaration is needed:
        # UnreadableInput is always in the rescue list, and this descends from it.
        class UnreadableDocument < ::HotCell::UnreadableInput; end

        private
          # Runs the tool with unsetenv_others and a written environment, and turns a non-zero exit into
          # `unreadable`. The tool's own stderr is the only useful diagnostic, and it is attacker-influenced,
          # so it is capped and scrubbed on its way onto the wire like any other error message.
          def run!(*command, pass: [])
            result = run_tool(*command, pass: pass)
            return result if result.ok?

            raise UnreadableDocument, "#{command.first} exited #{result.status.exitstatus}: " \
                                      "#{result.err.to_s.strip[0, 200]}"
          end

          # An empty output means the tool said it succeeded and produced nothing, which the client would
          # otherwise have to catch as zero bytes on a successful response. The caller measures the output
          # wherever it landed — the descriptor's own file for a tool that wrote it directly, or the staged
          # scratch path for one that could not.
          def produced!(bytes, command)
            raise UnreadableDocument, "#{command} wrote nothing" if bytes.zero?

            bytes
          end

          def positive_integer!(name, value, maximum)
            return value if value.is_a?(Integer) && value.positive? && value <= maximum

            refuse! "#{name} #{value.inspect} must be an integer between 1 and #{maximum}"
          end
      end
    end
  end
end
