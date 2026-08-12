# frozen_string_literal: true

require "active_storage/hot_cell/server/magick_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Transformers::ImageMagick` does, moved out of the application: the same
      # `source(file).loader(page: 0).convert(format).apply(operations)` pipeline, run through
      # ImageProcessing::MiniMagick.
      #
      # The transformation allowlist Rails' ImageMagick transformer enforces —
      # `supported_image_processing_methods` and the argument blocklist — runs on the client, where an
      # application's Rails configuration applies today, and is deliberately not repeated here. ImageProcessing
      # still refuses a name that is neither one of its operations nor a MiniMagick method, so `:system` and
      # friends cannot reach `magick`.
      class MagickTransformImageOperation < MagickOperation
        operation "active_storage.transform_image_imagemagick"

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

          { format: format, content_type: CONTENT_TYPES[format.downcase], bytes: File.size(destination.path) }.compact
        end

        private
          def pipeline(path, format, operations)
            ImageProcessing::MiniMagick
              .source(path)
              .loader(page: 0)
              .convert(format)
              .apply(operations_for(operations))
          end

          # The same shape the vips operation enforces, and the same shape Rails' shared transformer does:
          # refuse combine_options, and drop a transformation whose argument is blank so a blank never reaches
          # ImageProcessing, where it raises.
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
      end
    end
  end
end
