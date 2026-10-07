# frozen_string_literal: true

require "active_storage/hot_cell/server/previewers/pdf"

module ActiveStorage
  module HotCell
    module Server
      module Previewers
        class Pdf
          # What `ActiveStorage::Previewer::MuPDFPreviewer` does, moved out of the application.
          #
          # Rails runs `mutool draw -F png -o - <file> 1` and streams the result through the web process. This
          # writes to the worker's own scratch instead of to stdout.
          class Mutool < Pdf
            operation "active_storage.previewers.pdf.mutool"

            private
              # The input is read through its descriptor, but the output is staged: mutool unlinks its output
              # path before writing, and /dev/fd cannot be unlinked, so a passed output descriptor fails with
              # "Operation not permitted". The staged PNG is copied out by Output#post. Streaming mutool's
              # stdout to the descriptor — what Rails does with `-o -` — would remove the copy, and is a
              # separate change.
              def render(source, destination, page:, resolution:)
                run! "mutool", "draw", "-F", "png", "-r", resolution.to_s, "-o", destination.path,
                     source.fd_path, page.to_s, pass: [ source.to_io ],
                     causes: { /cannot authenticate password/ => ProtectedDocument }
              end

              def tool
                "mutool"
              end
          end
        end
      end
    end
  end
end
