# frozen_string_literal: true

require "active_storage/hot_cell/vips_operation"

module ActiveStorage
  module HotCell
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
    class TransformImage < VipsOperation
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

      # Loader and saver options are this operation's, never the caller's. They are not in the payload as
      # library keywords and not in the allowlist above.
      #
      # Two exceptions, and they are exceptions on purpose rather than by omission. `quality` and `strip` are
      # already signed into variant URLs that were minted years ago and never expire, so refusing them would
      # break every image in every email ever sent. They arrive as intent — "smaller" and "no metadata" — with
      # the operation still choosing what that means for the format it is writing.
      QUALITY = (1..100).freeze

      def perform(inputs, outputs, payload)
        source, = inputs
        destination, = outputs

        format = format!(payload)
        produced = pipeline(source.path, format, payload).call

        begin
          IO.copy_stream produced.path, destination.path
        ensure
          produced.close!
        end

        describe destination.path, format
      end

      private
        def pipeline(path, format, payload)
          ImageProcessing::Vips
            .source(path)
            .loader(**loader_for(payload))
            .convert(format)
            .saver(**saver_for(payload))
            .apply(operations_for(payload))
        end

        # `page: 0` is what Rails passes, and it is what stops a multi-page TIFF or a hundred-frame GIF from
        # being decoded in full to produce one thumbnail. `n: -1` is the opposite request, and the only way a
        # caller can ask for it is the `animated` intent flag.
        def loader_for(payload)
          payload[:animated] ? { n: -1 } : { page: 0 }
        end

        def saver_for(payload)
          {}.tap do |saver|
            saver[:strip] = true if payload[:strip]

            if (quality = payload[:quality])
              refuse! "quality #{quality.inspect} is not an integer between 1 and 100" unless QUALITY.cover?(quality)
              saver[:Q] = quality
            end
          end
        end

        def operations_for(payload)
          declared = payload[:operations] || {}
          refuse! "operations must be an object, and this is a #{declared.class}" unless declared.is_a?(Hash)

          declared.filter_map do |name, argument|
            refuse! "#{name} is not one of #{OPERATIONS.join(", ")}" unless OPERATIONS.include?(name.to_s)

            [ name, argument ] unless argument.nil? || argument == false
          end
        end

        # Read back what was just written. Several callers need it: an analyzer returns metadata and no bytes at
        # all, and a thumbnailer needs the output's own dimensions rather than the ones it asked for.
        #
        # This parses bytes libvips produced from a hostile input, in this worker. That is already true of
        # everything above, which is why this operation declares untrusted_input :in_process.
        def describe(path, format)
          image = ::Vips::Image.new_from_file(path)

          { format: format, content_type: FORMATS.fetch(format), bytes: File.size(path),
            tracked_mem_highwater: vips_highwater, **dimensions_of(image) }
        end
    end
  end
end
