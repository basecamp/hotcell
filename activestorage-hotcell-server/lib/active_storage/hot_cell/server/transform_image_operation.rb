# frozen_string_literal: true

require "active_storage/hot_cell/server/vips_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Transformers::ImageProcessingTransformer` does, moved out of the application.
      #
      # Rails builds `source(file).loader(page: 0).convert(format).apply(operations)` and validates nothing on the
      # vips path — `Transformers::Vips` overrides only `#processor`, so the transformation allowlist in
      # `ActiveStorage.supported_image_processing_methods` is enforced by the ImageMagick transformer alone.
      # Verified by reading 8.1, not inferred. So the allowlist below is not a second line of defence, it is the
      # only one there is.
      #
      # ImageProcessing does refuse a name that is not one of its own operations or a Vips::Image method, which
      # rules out `:system` and friends. What it leaves open is every one of libvips' several hundred image
      # operations, with caller-chosen arguments.
      class TransformImageOperation < VipsOperation
        operation "active_storage.transform_image"

        limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256

        # Verified against libvips 8.18 rather than copied from a list: every name here works through
        # ImageProcessing::Vips, and the ones a reader might expect to find — `thumbnail`, `blur`, `flop`, `trim`,
        # `extend`, `monochrome` — are absent because they raise on this path.
        #
        # Deliberately short. `linear`, `gamma`, `hist_equal`, `embed` and `premultiply` all work and are all
        # knobs an attacker-supplied URL could turn, and no application here asks for them. Adding one is a line.
        OPERATIONS = %w[
          resize_to_limit resize_to_fit resize_to_fill resize_and_pad resize_to_cover
          crop rotate autorot flip flatten smartcrop sharpen gaussblur colourspace invert
        ].freeze

        # `loader` and `saver` are pipeline configuration rather than transformations, and they are passed to
        # ImageProcessing exactly as Rails passes them.
        #
        # That means a caller can currently set libvips loader and saver options directly, including
        # `loader: { unlimited: true }`, which removes libvips' own denial-of-service limits. This is the same
        # capability Rails gives a caller today. It is acceptable here and not there because the cell's limits
        # are outside the library: RLIMIT_DATA, RLIMIT_FSIZE and the supervisor's wall-clock deadline still
        # apply, so a decode libvips has been told not to bound costs the caller a killed worker.
        #
        # Bounding what may appear inside them is a planned feature — see the allowlist note in the README.
        PIPELINE = %w[ loader saver ].freeze

        def perform(inputs, outputs, format:, operations: {})
          source, = inputs
          destination, = outputs

          format = format!(format)
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

          def operations_for(declared)
            refuse! "operations must be an object, and this is a #{declared.class}" unless declared.is_a?(Hash)

            declared.filter_map do |name, argument|
              refuse! "#{name} is not one of #{allowed.join(", ")}" unless allowed.include?(name.to_s)

              [ name, argument ] unless argument.nil? || argument == false
            end
          end

          def allowed
            @allowed ||= (OPERATIONS + PIPELINE).freeze
          end

          # Read back what was just written. Several callers need it: an analyzer returns metadata and no bytes at
          # all, and a thumbnailer needs the output's own dimensions rather than the ones it asked for.
          #
          # This parses bytes libvips produced from a hostile input, in this worker. That is already true of
          # everything above: this operation parses hostile bytes in the worker, and reading its own output
          # is one more place it does so.
          def describe(path, format)
            image = ::Vips::Image.new_from_file(path)

            { format: format, content_type: FORMATS.fetch(format), bytes: File.size(path),
              tracked_mem_highwater: vips_highwater, **dimensions_of(image) }
          end
      end
    end
  end
end
