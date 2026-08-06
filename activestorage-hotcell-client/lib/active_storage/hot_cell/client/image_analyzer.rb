# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      # Shipping this is mandatory rather than a nicety.
      #
      #   config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::ImageAnalyzer
      #
      # The built-in image analyzers gate `accept?` on `variant_processor` being `:vips` or `:mini_magick`, so a
      # class value makes all of them decline, `analyzer_class` falls through to NullAnalyzer, and the blob is
      # marked analyzed with no dimensions at all. rails/rails#58384 leaves that to us deliberately.
      class ImageAnalyzer < ActiveStorage::Analyzer
        def self.accept?(blob)
          blob.image?
        end

        # Width and height, which is exactly what the built-in analyzer returns. The cell knows more — page count,
        # whether the image is animated — and surfacing it would change the shape of every blob's metadata, so a
        # subclass is the place for that rather than here.
        #
        # **Which way this fails is the whole design of the method.** The built-in vips analyzer rescues every
        # Vips::Error and returns an empty hash, which Rails then merges with `analyzed: true` — so an undecodable
        # image is recorded as successfully analyzed, forever, and nothing ever re-enqueues AnalyzeJob. That is
        # right for a permanent verdict and catastrophic for a transient one.
        #
        # So a permanent failure follows the built-in behaviour and lets the blob be marked analyzed, with the
        # reason written to the log so it can be re-decided later against a newer library. A transient failure is
        # not rescued at all, which is what leaves the blob `analyzed: false` and eligible to be tried again.
        def metadata
          measured.slice(:width, :height)
        rescue AnalyzeImage.cell.permanent => error
          logger.warn "hotcell: #{blob.filename} could not be analyzed and will not be retried: #{error.message}"
          {}
        end

        private
          def measured
            download_blob_to_tempfile do |file|
              File.open(file.path, "rb") { |readable| AnalyzeImage.perform_in_hotcell [ readable ], [], {} }
            end
          end
      end
    end
  end
end
