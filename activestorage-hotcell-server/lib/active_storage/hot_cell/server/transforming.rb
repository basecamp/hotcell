# frozen_string_literal: true

require "active_storage/hot_cell/server/operation"

module ActiveStorage
  module HotCell
    module Server
      # The transform shared by the two toolchains. An includer names its ImageProcessing backend with
      # `processor`, how the source reaches it with `source_path`, and what it reports with `describe`.
      module Transforming
        def perform(inputs, outputs, format:, operations: {})
          source, = inputs
          destination, = outputs

          format = format.to_s

          # ImageProcessing chooses its saver from the destination's extension, and a scratch path has none,
          # so encode to a suffixed sibling on the slot's own scratch and adopt it into place. That is one
          # rename rather than the copy-out-of-Dir.tmpdir that a destination-less `call` would do, and it
          # keeps ImageProcessing's own saver — quality, strip, format defaults — rather than reaching past
          # it to the library, which cannot reproduce those without restating them. Output#post makes the
          # one remaining copy, out through the caller's descriptor.
          encoded = destination.path(extension: format)
          pipeline(source, format, operations).call(destination: encoded)
          destination.adopt encoded

          describe destination.path, format
        end

        private
          # Three `loader` calls, and the order is the point: ImageProcessing merges them key by key, so the
          # last one to write a key wins.
          #
          # `page: 0` is first, as a default the caller may replace. It is what Rails does, and what stops a
          # multi-page TIFF or a hundred-frame GIF being decoded in full to produce one thumbnail; a caller
          # who wants every frame sends `loader: { n: -1 }` through `apply` and gets it.
          #
          # `source_loader_options` is last, so the caller cannot replace it.
          def pipeline(source, format, operations)
            processor
              .source(source_path(source))
              .loader(page: 0)
              .convert(format)
              .apply(operations_for(operations))
              .loader(**source_loader_options(source))
          end

          # What the toolchain needs in order to reach the source at all, which is not the same question as how
          # the image is decoded. Empty here, because `source_path` normally answers a filename and a filename
          # needs no help. An includer whose `source_path` names something the tool cannot open on its own
          # overrides this to supply the rest — `Transformers::Image::Magick` is the one that does.
          #
          # It goes last in `pipeline` because it is not the caller's to change: a payload sending
          # `loader: { inherit_fds: [] }` would otherwise leave the source naming a descriptor the tool has no
          # way to open.
          def source_loader_options(_source)
            {}
          end

          # What Rails validates, and no more. `combine_options` is refused because it can never be one
          # pipeline, and a blank argument means "skip this operation" — Rails filters on `present?`, and the
          # test below is that semantic reimplemented, because the cell does not load Active Support.
          #
          # **Accepted risk.** Any other name reaches ImageProcessing, which dispatches it to the backend.
          # `ImageProcessing.unsafe_method?` stops the Ruby core methods, so `send` and `system` cannot be
          # reached, and it does not stop a genuine one: `write_to_file` and `dzsave` are real libvips
          # operations that write where they are told. The premise is that the transformations come from the
          # trusted side, and that this is no more permissive than stock Rails, whose own Vips transformer
          # refuses `combine_options` and nothing else. The ImageMagick allowlist Rails added after
          # CVE-2022-21831 runs on the client, where the application's configuration for it applies — see
          # `Transformers::Image::Magick` on that side, which calls `operations` for that effect.
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
