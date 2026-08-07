# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/image_analyzer"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class ImageAnalyzer
          # What an application prepends onto `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips
          #
          # Named for its toolchain the way ActiveStorage::Analyzer::ImageAnalyzer::Vips is. The library itself is
          # in the cell, so what this names is which operation to ask — an ImageMagick sibling reaches a cell
          # carrying ImageMagick and differs in nothing else.
          class Vips < ImageAnalyzer
            self.client = AnalyzeImage
          end
        end
      end
    end
  end
end
