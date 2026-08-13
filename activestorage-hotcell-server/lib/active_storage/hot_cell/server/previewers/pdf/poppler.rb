# frozen_string_literal: true

require "active_storage/hot_cell/server/previewers/pdf"

module ActiveStorage
  module HotCell
    module Server
      module Previewers
        class Pdf
          # What `ActiveStorage::Previewer::PopplerPDFPreviewer` does, moved out of the application: the Poppler
          # sibling of the mutool preview, for an image whose Rails default previewer chain reaches pdftoppm
          # first.
          #
          # Rails runs `pdftoppm -singlefile -cropbox -r 72 -png <file>` and streams the result through the web
          # process. This reads the input through its descriptor and writes to the worker's own scratch.
          class Poppler < Pdf
            operation "active_storage.previewers.pdf.poppler"

            private
              # pdftoppm appends `.png` to its output root, so the frame lands beside the scratch name and is
              # adopted into place; Output#post makes the one copy out through the caller's descriptor.
              def render(source, destination, page:, resolution:)
                run! "pdftoppm", "-png", "-singlefile", "-cropbox", "-r", resolution.to_s,
                     "-f", page.to_s, "-l", page.to_s, source.fd_path, destination.path,
                     pass: [ source.to_io ]

                destination.adopt destination.path(extension: "png")
              end

              def tool
                "pdftoppm"
              end
          end
        end
      end
    end
  end
end
