# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/image_analyzer"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class ImageAnalyzer
          # What an application on ImageMagick prepends onto `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::ImageMagick
          #
          # Named for its toolchain the way ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick is. The library
          # is in the cell; this names which operation to ask. It shares the base's width-and-height slice and
          # its permanent-versus-transient split, differing only in the client it reaches.
          class ImageMagick < ImageAnalyzer
            self.client = MagickAnalyzeImage
          end
        end
      end
    end
  end
end
