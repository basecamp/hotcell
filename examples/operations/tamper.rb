# frozen_string_literal: true

# What a cell can do to the caller's files beyond what it was given, reported rather than assumed. The
# shared group buys a cell one thing in each direction: it may read an input and write an output. Every
# answer here must be a refusal.
#
# Opening is the whole test, so nothing is written. The two access modes are the caller's file modes, and a
# cell cannot widen them: changing a mode needs ownership, the caller owns these files, and `cap-drop ALL`
# leaves no capability that overrides that.
module Examples
  class Tamper < HotCell::Operation
    operation "example.tamper"

    def perform(inputs, outputs)
      source, = inputs
      destination, = outputs

      refusals = { write_input: attempt { File.open(source.fd_path, "r+") { nil } },
                   read_output: attempt { File.open(destination.fd_path, "rb") { nil } },
                   chmod_input: attempt { File.chmod(0o600, source.fd_path) } }

      # The permitted direction, through the descriptor. It also keeps the response legal, because an
      # output that receives no bytes is a failure however the operation answered.
      destination.to_io.write "probed"

      refusals
    end

    private
      def attempt
        yield
        "succeeded"
      rescue SystemCallError => error
        error.class.name.split("::").last
      end
  end
end
