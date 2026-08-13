# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

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
        # This holds the Rails-facing contract — which blobs are accepted, which keys are written. A leaf names
        # the client that reaches its toolchain and differs in nothing else.
        class Image < ActiveStorage::Analyzer
          include Analyzing

          # Width and height, which is exactly what the built-in analyzer returns. The cell knows more — page
          # count, whether the image is animated — and surfacing it would change the shape of every blob's
          # metadata.
          KEYS = %i[ width height ].freeze

          def self.accept?(blob)
            blob.image?
          end
        end
      end
    end
  end
end
