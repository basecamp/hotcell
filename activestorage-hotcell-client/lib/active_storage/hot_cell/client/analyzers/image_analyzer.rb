# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/analyzing"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # Shipping an analyzer is mandatory rather than a nicety. The built-in image analyzers gate `accept?` on
        # `variant_processor` being `:vips` or `:mini_magick`, so a class value makes all of them decline,
        # `analyzer_class` falls through to NullAnalyzer, and the blob is marked analyzed with no dimensions at
        # all. rails/rails#58384 leaves that to us deliberately.
        #
        # This holds everything that does not depend on which toolchain the cell carries. A subclass names the
        # client that reaches that toolchain, the way ActiveStorage::Analyzer::ImageAnalyzer::Vips does.
        class ImageAnalyzer < ActiveStorage::Analyzer
          include Analyzing

          # Width and height, which is exactly what the built-in analyzer returns. The cell knows more — page
          # count, whether the image is animated — and surfacing it would change the shape of every blob's
          # metadata.
          KEYS = %i[ width height ].freeze

          def self.accept?(blob)
            blob.image?
          end

          # What an application prepends onto `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips
          #
          # Named for its toolchain the way ActiveStorage::Analyzer::ImageAnalyzer::Vips is. The library itself
          # is in the cell, so what a subclass names is which operation to ask — the ImageMagick sibling reaches
          # a cell carrying ImageMagick and differs in nothing else.
          class Vips < ImageAnalyzer
            self.client = AnalyzeImage
          end

          class ImageMagick < ImageAnalyzer
            self.client = MagickAnalyzeImage
          end
        end
      end
    end
  end
end
