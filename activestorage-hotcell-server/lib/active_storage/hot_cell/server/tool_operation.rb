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

          # Extra command-line arguments an application configures — `config.active_storage.ffprobe_arguments`
          # and its siblings — spliced into the tool's argv at the position that setting names. The client
          # splits the shell string, so what arrives is already argv, and this checks only that it is: what
          # the flags mean is the application's decision, exactly as it is when Rails runs the tool itself.
          #
          # **Accepted risk.** These are tool options and nothing here restricts which. `-o` makes ffprobe
          # write a file, `-dump_attachment` makes ffmpeg extract one, and no shell is involved in either.
          # The premise is that the payload comes from the trusted side: an application's own configuration
          # crosses a socket only that application can reach, and Rails hands the same strings to the same
          # tools when it runs them itself. An allowlist here would be a second, worse copy of a decision the
          # application already made. What would change the premise is the work socket becoming reachable by
          # something other than the application.
          def arguments!(name, value)
            return value if value.is_a?(Array) && value.all?(String)

            refuse! "#{name} must be an array of strings, and this is #{value.inspect[0, 80]}"
          end
      end
    end
  end
end
