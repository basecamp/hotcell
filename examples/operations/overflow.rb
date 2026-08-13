# frozen_string_literal: true

# Writes the payload's megabytes straight through the caller's output descriptor. Past the cell's
# file-size limit the kernel raises SIGXFSZ and the verdict is `killed: fsize`.
module Examples
  class Overflow < HotCell::Operation
    operation "example.overflow"

    def perform(_inputs, outputs, megabytes:)
      sink = outputs.first.to_io
      megabytes.times { sink.write "x" * 1024**2 }
      sink.flush

      {}
    end
  end
end
