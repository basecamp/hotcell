# frozen_string_literal: true

require "active_storage/hot_cell/server/vips_operation"
require "active_storage/hot_cell/server/transforming"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Transformers::ImageProcessingTransformer` does, moved out of the application, and
      # deliberately nothing more: the transformations and the format reach ImageProcessing exactly as Rails
      # hands them over.
      #
      # There is no allowlist here, and that mirrors Rails: the vips path validates exactly one thing —
      # `combine_options` is refused — and `ActiveStorage.supported_image_processing_methods` is enforced by
      # the ImageMagick transformer alone. ImageProcessing itself refuses a name that is not one of its own
      # operations or a `Vips::Image` method, which rules out `:system` and friends. Bounding the operation
      # set and the keys inside `loader`/`saver` is a planned, separate deliverable — see the README — and
      # until then the cell's limits are the bound: RLIMIT_DATA, RLIMIT_FSIZE and the deadline still apply,
      # so a pipeline libvips has been told not to bound costs the caller a killed worker.
      class TransformImageOperation < VipsOperation
        include Transforming

        operation "active_storage.transform_image"

        limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256

        private
          def processor
            ImageProcessing::Vips
          end

          def source_path(source)
            source.fd_path
          end

          # Read back what was just written. Several callers need it: an analyzer returns metadata and no bytes at
          # all, and a thumbnailer needs the output's own dimensions rather than the ones it asked for.
          #
          # This parses bytes libvips produced from a hostile input, in this worker. That is already true of
          # everything above: this operation parses hostile bytes in the worker, and reading its own output
          # is one more place it does so.
          def describe(path, format)
            image = ::Vips::Image.new_from_file(path)

            { format: format, content_type: CONTENT_TYPES[format.downcase], bytes: File.size(path),
              tracked_mem_highwater: vips_highwater, **dimensions_of(image) }.compact
          end
      end
    end
  end
end
