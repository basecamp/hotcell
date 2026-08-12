# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_storage/previewer/mupdf_previewer"
require "active_storage/previewer/poppler_pdf_previewer"
require "active_storage/previewer/video_previewer"
require "active_support/core_ext/class/attribute"

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
        def self.included(previewer)
          previewer.class_attribute :client, instance_accessor: false
        end

        def preview(**options)
          download_blob_to_tempfile do |input|
            render_through(input) do |attachable|
              yield(**attachable, **options)
            end
          end
        end

        private
          # The filename extension and content type come from the cell's own result rather than being
          # restated here, so the operation is the one source of truth for what it produced. The scratch
          # tempfile's name never reaches Rails — only the yielded filename does.
          def render_through(input)
            Tempfile.create("hotcell-preview", binmode: true) do |output|
              result = File.open(input.path, "rb") do |readable|
                File.open(output.path, "wb") do |writable|
                  self.class.client.perform_in_hotcell [ readable ], [ writable ]
                end
              end

              File.open(output.path, "rb") do |io|
                yield io: io, filename: "#{blob.filename.base}.#{result[:format]}",
                      content_type: result[:content_type]
              end
            end
          end
      end

      class PdfPreviewer < ActiveStorage::Previewer::MuPDFPreviewer
        include Previewing

        self.client = PreviewPdf

        # Delegates to the superclass's content-type predicate rather than restating the list, so the accepted set
        # cannot drift away from the one Rails ships.
        def self.accept?(blob)
          pdf? blob.content_type
        end
      end

      # The Poppler sibling of PdfPreviewer, for an application whose image carries pdftoppm rather than
      # mutool — the previewer Rails' default chain reaches first.
      class PopplerPdfPreviewer < ActiveStorage::Previewer::PopplerPDFPreviewer
        include Previewing

        self.client = PreviewPdfPoppler

        def self.accept?(blob)
          pdf? blob.content_type
        end
      end

      class VideoPreviewer < ActiveStorage::Previewer::VideoPreviewer
        include Previewing

        self.client = PreviewVideo

        # blob.video? is the content-type predicate the superclass uses; ffmpeg_exists? is the part that has to go.
        def self.accept?(blob)
          blob.video?
        end
      end
    end
  end
end
