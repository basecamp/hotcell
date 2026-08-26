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

              def source_path(source)
                source.fd_path
              end

              # `source_path` names the input as the source's `/dev/fd` path, which `magick` can open only if it
              # inherits the descriptor, so name the IO for mini_magick to put in its spawn map. Through the
              # loader options rather than by pre-building a MiniMagick::Tool: a pre-built tool reaches
              # ImageProcessing's `load_image` by its first branch, which drops `page`, `loader` and `geometry`
              # without a word.
              def source_loader_options(source)
                { inherit_fds: [ source.to_io ] }
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
