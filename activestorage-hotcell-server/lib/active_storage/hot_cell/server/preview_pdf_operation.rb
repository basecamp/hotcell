# frozen_string_literal: true

require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      # What the two PDF previewers share: one bounded page, rendered to PNG on the worker's own scratch, so
      # a pathological page cannot be answered by buffering an unbounded PNG in memory — the file is bounded
      # by the cell's `file_size` limit and the kernel enforces it. A subclass supplies the tool run.
      #
      # The result carries no dimensions, and that is what Rails does rather than a concession to make here. A
      # previewer yields `io:`, `filename:` and `content_type:` and nothing else; `Preview#process` attaches that
      # as a new blob, and the dimensions come later from analyzing *that* blob like any other. So a drop-in
      # replacement returns no dimensions either.
      #
      # It is also what keeps the `:subprocess` claim true. Reading the produced PNG here would mean parsing
      # bytes the tool just made out of a hostile PDF, in this worker, which is exactly what turns a
      # subprocess operation into an in-process one.
      class PreviewPdfOperation < ToolOperation
        abstract_operation

        limits deadline: 30, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 128

        MAX_PAGE = 10_000
        MAX_RESOLUTION = 600

        def perform(inputs, outputs, page: 1, resolution: 72)
          source, = inputs
          destination, = outputs

          page = positive_integer!(:page, page, MAX_PAGE)
          resolution = positive_integer!(:resolution, resolution, MAX_RESOLUTION)

          render source, destination, page: page, resolution: resolution

          staged = File.exist?(destination.path) ? File.size(destination.path) : 0

          { format: "png", content_type: "image/png", page: page, resolution: resolution,
            bytes: produced!(staged, tool) }
        end
      end
    end
  end
end
