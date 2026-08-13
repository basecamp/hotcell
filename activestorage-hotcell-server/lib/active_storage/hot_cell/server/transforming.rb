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
          pipeline(source_path(source), format, operations).call(destination: encoded)
          destination.adopt encoded

          describe destination.path, format
        end

        private
          # `loader(page: 0)` first is what Rails does, and it is what stops a multi-page TIFF or a
          # hundred-frame GIF being decoded in full to produce one thumbnail. A caller's own `loader` arrives
          # through `apply` and merges over it, which is also what Rails does — asking for every frame is
          # `loader: { n: -1 }`.
          def pipeline(path, format, operations)
            processor
              .source(path)
              .loader(page: 0)
              .convert(format)
              .apply(operations_for(operations))
          end

          # What Rails validates, and no more. `combine_options` is refused because it can never be one
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
      end
    end
  end
end
