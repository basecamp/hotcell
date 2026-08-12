# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_storage/transformers/image_magick"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      module Transformers
        # What Rails configures as `config.active_storage.variant_processor` for an application on ImageMagick.
        #
        #   config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::ImageMagick
        #
        # It subclasses Rails' own ImageMagick transformer to keep its transformation allowlist —
        # `supported_image_processing_methods` and the argument blocklist — which runs here, in the
        # application, exactly where Rails runs it today. Only the final step changes: rather than shelling out
        # to `magick` locally, the validated transformations cross to the cell.
        class ImageMagick < ActiveStorage::Transformers::ImageMagick
          private
            # `operations` is Rails' validation: it raises UnsupportedImageProcessingMethod or
            # UnsupportedImageProcessingArgument for anything outside the allowlist. Called for that effect,
            # then the transformations travel to the cell as the application wrote them, Symbol values turned
            # to the Strings ImageMagick would have been handed.
            def process(file, format:)
              operations

              output = Tempfile.new([ "hotcell", ".#{format}" ], binmode: true)

              begin
                convert file, output, format: format.to_s, operations: stringified(transformations)
                output.tap(&:rewind)
              rescue StandardError
                output.close!
                raise
              end
            end

            def convert(file, output, **payload)
              File.open(file.path, "rb") do |readable|
                File.open(output.path, "wb") do |writable|
                  MagickTransformImage.perform_in_hotcell [ readable ], [ writable ], payload
                end
              end
            end

            def stringified(value)
              case value
              when Symbol then value.to_s
              when Hash   then value.transform_values { |nested| stringified(nested) }
              when Array  then value.map { |nested| stringified(nested) }
              else value
              end
            end
        end
      end
    end
  end
end
