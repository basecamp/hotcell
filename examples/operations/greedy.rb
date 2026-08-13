# frozen_string_literal: true

# Allocates the payload's megabytes in one buffer — the decompression-bomb shape. Past the cell's memory
# limit the allocation raises NoMemoryError and the verdict is `killed: memory`, where RLIMIT_DATA is
# enforceable.
module Examples
  class Greedy < HotCell::Operation
    operation "example.greedy"

    def perform(_inputs, _outputs, megabytes:)
      { bytes: ("x" * (megabytes * 1024**2)).bytesize }
    end
  end
end
