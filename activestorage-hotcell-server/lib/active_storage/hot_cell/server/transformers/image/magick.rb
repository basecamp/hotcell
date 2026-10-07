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

              # ImageMagick takes an explicit format only as a coder name, `jfif:/path`, and it has no coder for
              # every format Rails asks for: Marcel maps `.jfif`, `.jif` and `.jfi` to image/jpeg, so a JPEG
              # uploaded under one of them asks for that format, and the prefix reads as a filename that does not
              # exist (#84). Named by extension instead, ImageMagick picks the coder from a suffix it knows and
              # keeps the source's format for one it does not, which is what stock Rails gets from the tempfile
              # ImageProcessing names for it. The vips toolchain keeps the direct write.
              def encoded_path(destination, format)
                destination.path(extension: format)
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
