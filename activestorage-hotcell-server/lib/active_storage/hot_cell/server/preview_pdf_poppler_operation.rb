# frozen_string_literal: true

require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Previewer::PopplerPDFPreviewer` does, moved out of the application: the Poppler
      # sibling of the mutool preview, for an image whose Rails default previewer chain reaches pdftoppm first.
      #
      # Rails runs `pdftoppm -singlefile -cropbox -r 72 -png <file>` and streams the result through the web
      # process. This reads the input through its descriptor and writes to the worker's own scratch, bounded
      # by the cell's file_size, rather than buffering an unbounded PNG in memory. pdftoppm appends `.png` to
      # its output root, so the frame lands beside the scratch name and is renamed into place; Output#post
      # makes the one copy out through the caller's descriptor.
      #
      # No dimensions, and no bytes read back here: reading the produced PNG would parse bytes pdftoppm just
      # made from a hostile PDF, in this worker, which is what turns a subprocess operation into an in-process
      # one.
      class PreviewPdfPopplerOperation < ToolOperation
        operation "active_storage.preview_pdf_poppler"

        limits deadline: 30, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 128

        MAX_PAGE = 10_000
        MAX_RESOLUTION = 600

        def perform(inputs, outputs, page: 1, resolution: 72)
          source, = inputs
          destination, = outputs

          page = positive_integer!(:page, page, MAX_PAGE)
          resolution = positive_integer!(:resolution, resolution, MAX_RESOLUTION)

          run! "pdftoppm", "-png", "-singlefile", "-cropbox", "-r", resolution.to_s,
               "-f", page.to_s, "-l", page.to_s, source.fd_path, destination.path,
               pass: [ source.to_io ]

          rendered = "#{destination.path}.png"
          File.rename rendered, destination.path if File.exist?(rendered)
          staged = File.exist?(destination.path) ? File.size(destination.path) : 0

          { format: "png", content_type: "image/png", page: page, resolution: resolution,
            bytes: produced!(staged, "pdftoppm") }
        end
      end
    end
  end
end
