# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_storage/previewer/mupdf_previewer"
require "active_storage/previewer/video_previewer"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      # What Rails configures as `config.active_storage.previewers`.
      #
      #   config.active_storage.previewers = [ ActiveStorage::HotCell::Client::PdfPreviewer,
      #                                        ActiveStorage::HotCell::Client::VideoPreviewer ]
      #
      # **`accept?` must not probe for a binary, and that is the reason these exist as much as the sandboxing is.**
      # `MuPDFPreviewer.accept?` calls `mutool_exists?` and `VideoPreviewer.accept?` calls `ffmpeg_exists?`, both
      # shelling out with `system` from inside a web request. The moment those binaries leave the application
      # image — which is the point of moving the work into a cell — both answer false, `previewable?` goes false
      # with them, and previews stop existing. No exception, no alert, nothing in a log.
      #
      # The sequencing matters as much as the override: these ship and are verified *before* the binary leaves the
      # application image, because the window between those two events fails silently.
      module Previewing
        private
          def render_through(client, input, extension, content_type, payload = {})
            Tempfile.create([ "hotcell-preview", extension ], binmode: true) do |output|
              File.open(input.path, "rb") do |readable|
                File.open(output.path, "wb") { |writable| client.perform_in_hotcell [ readable ], [ writable ], payload }
              end

              File.open(output.path, "rb") do |io|
                yield io: io, filename: "#{blob.filename.base}#{extension}", content_type: content_type
              end
            end
          end
      end

      class PdfPreviewer < ActiveStorage::Previewer::MuPDFPreviewer
        include Previewing

        # Delegates to the superclass's content-type predicate rather than restating the list, so the accepted set
        # cannot drift away from the one Rails ships.
        def self.accept?(blob)
          pdf? blob.content_type
        end

        def preview(**options)
          download_blob_to_tempfile do |input|
            render_through(PreviewPdf, input, ".png", "image/png") do |attachable|
              yield(**attachable, **options)
            end
          end
        end
      end

      class VideoPreviewer < ActiveStorage::Previewer::VideoPreviewer
        include Previewing

        # blob.video? is the content-type predicate the superclass uses; ffmpeg_exists? is the part that has to go.
        def self.accept?(blob)
          blob.video?
        end

        def preview(**options)
          download_blob_to_tempfile do |input|
            render_through(PreviewVideo, input, ".jpg", "image/jpeg") do |attachable|
              yield(**attachable, **options)
            end
          end
        end
      end
    end
  end
end
