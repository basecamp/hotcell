# frozen_string_literal: true

require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Previewer::MuPDFPreviewer` does, moved out of the application.
      #
      # Rails runs `mutool draw -F png -o - <file> 1` and streams the result through the web process. This writes
      # to the worker's own scratch instead of to stdout, so a pathological page cannot be answered by buffering an
      # unbounded PNG in memory — the file is bounded by the cell's `file_size` limit and the kernel enforces it.
      #
      # The result carries no dimensions, and that is what Rails does rather than a concession to make here. A
      # previewer yields `io:`, `filename:` and `content_type:` and nothing else; `Preview#process` attaches that as
      # a new blob, and the dimensions come later from analyzing *that* blob like any other. So a drop-in
      # replacement returns no dimensions either.
      #
      # It is also what keeps the `:subprocess` claim true. Reading the produced PNG here would mean parsing bytes
      # mutool just made out of a hostile PDF, in this worker, which is exactly what turns a subprocess operation
      # into an in-process one.
      class PreviewPdf < ToolOperation
        operation "active_storage.preview_pdf"

        limits deadline: 30, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 128

        MAX_PAGE = 10_000
        MAX_RESOLUTION = 600

        def perform(inputs, outputs, payload)
          source, = inputs
          destination, = outputs

          page = positive_integer!(payload, :page, 1, MAX_PAGE)
          resolution = positive_integer!(payload, :resolution, 72, MAX_RESOLUTION)

          run! "mutool", "draw", "-F", "png", "-r", resolution.to_s, "-o", destination.path,
               source.path, page.to_s

          { format: "png", content_type: "image/png", page: page, resolution: resolution,
            bytes: produced!(destination.path, "mutool") }
        end
      end
    end
  end
end
