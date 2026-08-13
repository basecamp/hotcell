# frozen_string_literal: true

require "active_storage"
require "active_storage/transformers/image_magick"

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/transformers/transforming"

module ActiveStorage
  module HotCell
    module Client
      module Transformers
        module Image
          # What Rails configures as `config.active_storage.variant_processor` for an application on ImageMagick.
          #
          #   config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Image::Magick
          #
          # It subclasses Rails' own ImageMagick transformer to keep its transformation allowlist —
          # `supported_image_processing_methods` and the argument blocklist — which runs here, in the
          # application, exactly where Rails runs it today. Only the final step changes: rather than shelling out
          # to `magick` locally, the validated transformations cross to the cell.
          class Magick < ActiveStorage::Transformers::ImageMagick
            include Transforming

            self.client = Operations::Transformers::Image::Magick

            private
              # `operations` is Rails' validation: it raises UnsupportedImageProcessingMethod or
              # UnsupportedImageProcessingArgument for anything outside the allowlist. Called for that effect,
              # then the transformations travel to the cell as the application wrote them.
              def process(file, format:)
                operations

                super
              end
          end
        end
      end
    end
  end
end
