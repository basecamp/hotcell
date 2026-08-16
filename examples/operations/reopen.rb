# frozen_string_literal: true

# The same round trip as echo, through both paths instead of both descriptors. `/dev/fd/N` is a fresh
# open, rechecked against the opening process's uid and the file's mode, so this succeeds only when the
# cell can open the caller's own files by name. Echo consumes the descriptors directly and never
# establishes that, which is why both exist.
#
# Both directions, because they are different permissions and a tool may need either: an input is readable
# by the group and an output is writable by it, and one of the shipped operations re-opens each. Reading
# alone would pass on a cell whose outputs the group cannot write, where every ffmpeg preview fails.
#
# In process rather than through an exec'd tool, so the check needs no toolchain: a spawned child opens
# the same paths as the same uid and fails identically.
module Examples
  class Reopen < HotCell::Operation
    operation "example.reopen"

    def perform(inputs, outputs)
      source, = inputs
      destination, = outputs

      bytes = File.open(source.fd_path, "rb") do |input|
        File.open(destination.fd_path, "wb") { |output| output.write(input.read) }
      end

      { bytes: bytes, staged: source.staged? || destination.staged? }
    end
  end
end
