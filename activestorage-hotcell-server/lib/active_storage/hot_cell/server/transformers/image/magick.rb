# frozen_string_literal: true

require "active_storage/hot_cell/server/magick_operation"
require "active_storage/hot_cell/server/transforming"

module ActiveStorage
  module HotCell
    module Server
      module Transformers
        module Image
          # What `ActiveStorage::Transformers::ImageMagick` does, moved out of the application: the same
          # `source(file).loader(page: 0).convert(format).apply(operations)` pipeline, run through
          # ImageProcessing::MiniMagick.
          #
          # The transformation allowlist Rails' ImageMagick transformer enforces —
          # `supported_image_processing_methods` and the argument blocklist — runs on the client, where an
          # application's Rails configuration applies today, and is deliberately not repeated here.
          # ImageProcessing still refuses a name that is neither one of its operations nor a MiniMagick method,
          # so `:system` and friends cannot reach `magick`.
          class Magick < MagickOperation
            include Transforming

            operation "active_storage.transformers.image.magick"

            limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256

            private
              def processor
                ImageProcessing::MiniMagick
              end

              # The staged path rather than /dev/fd; MagickOperation's comment says why.
              def source_path(source)
                source.path
              end

              def describe(path, format)
                { format: format, content_type: CONTENT_TYPES[format.downcase], bytes: File.size(path) }.compact
              end
          end
        end
      end
    end
  end
end
