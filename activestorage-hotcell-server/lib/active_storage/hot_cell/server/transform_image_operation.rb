# frozen_string_literal: true

require "active_storage/hot_cell/server/vips_operation"

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
        operation "active_storage.transform_image"

        limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256

        def perform(inputs, outputs, format:, operations: {})
          source, = inputs
          destination, = outputs

          format = format.to_s
          produced = pipeline(source.path, format, operations).call

          begin
            IO.copy_stream produced.path, destination.path
          ensure
            produced.close!
          end

          describe destination.path, format
        end

        private
          # `loader(page: 0)` first is what Rails does, and it is what stops a multi-page TIFF or a
          # hundred-frame GIF being decoded in full to produce one thumbnail. A caller's own `loader` arrives
          # through `apply` and merges over it, which is also what Rails does — asking for every frame is
          # `loader: { n: -1 }`.
          def pipeline(path, format, operations)
            ImageProcessing::Vips
              .source(path)
              .loader(page: 0)
              .convert(format)
              .apply(operations_for(operations))
          end

          # What Rails validates, and no more. `combine_options` is refused because it can never be one vips
          # pipeline, and a blank argument means "skip this operation" — Rails filters on `present?`, and the
          # test below is that semantic reimplemented, because the cell does not load Active Support.
          def operations_for(declared)
            refuse! "operations must be an object, and this is a #{declared.class}" unless declared.is_a?(Hash)

            declared.filter_map do |name, argument|
              if name.to_s == "combine_options"
                refuse! "combine_options is not supported, because it cannot generate a single command"
              end

              [ name, argument ] unless blank?(argument)
            end
          end

          def blank?(argument)
            return true if argument.nil? || argument == false
            return argument.match?(/\A[[:space:]]*\z/) if argument.is_a?(String)

            argument.respond_to?(:empty?) && argument.empty?
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
