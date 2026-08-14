# frozen_string_literal: true

# The same round trip as echo, reading the input through its path instead of through the descriptor.
# `/dev/fd/N` is a fresh open, rechecked against the opening process's uid and the file's mode, so this
# succeeds only when the cell can open the caller's own file by name. Echo consumes the descriptor
# directly and never establishes that, which is why both exist.
#
# In process rather than through an exec'd tool, so the check needs no toolchain: a spawned child opens
# the path as the same uid and fails identically.
module Examples
  class Reopen < HotCell::Operation
    operation "example.reopen"

    def perform(inputs, outputs)
      source, = inputs
      bytes = File.open(source.fd_path, "rb") { |file| outputs.first.to_io.write(file.read) }

      { bytes: bytes, staged: source.staged? }
    end
  end
end
