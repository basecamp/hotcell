# frozen_string_literal: true

require "active_storage/hot_cell/server/vips_operation"

module ActiveStorage
  module HotCell
    module Server
      # Metadata and no bytes, which is the request shape with no outputs at all.
      #
      # Shipping this is mandatory rather than a nicety. The built-in image analyzers gate `accept?` on
      # `variant_processor` being `:vips` or `:mini_magick`, so a class value makes them all decline,
      # `analyzer_class` falls through to `NullAnalyzer`, and the blob is marked analyzed with no dimensions at all.
      #
      # There is a sharper version of the same problem inside the built-in vips analyzer, which this deliberately
      # does not copy: it rescues every Vips::Error and returns an empty hash, which is then merged with
      # `analyzed: true`. An undecodable image is recorded as successfully analyzed, forever, and nothing
      # re-enqueues AnalyzeJob. Here an undecodable input raises Vips::Error, the cell answers `unreadable`, and
      # the client decides — because only the client knows whether that verdict is safe to write down.
      class AnalyzeImage < VipsOperation
        operation "active_storage.analyze_image"

        # Analysis reads a header rather than decoding a whole image, so it gets far less room than a transform.
        limits deadline: 10, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 64

        def perform(inputs, _outputs, _payload)
          source, = inputs
          image = ::Vips::Image.new_from_file(source.path, access: :sequential)

          { **dimensions_of(image), **frames_of(image),
            bytes: File.size(source.path), tracked_mem_highwater: vips_highwater }
        end

        private
          # `pages` is what tells a caller whether asking for `animated: true` would mean anything, and it is one
          # of the things BC4's own analyzer produces that Rails' does not.
          def frames_of(image)
            pages = image.get("n-pages").to_i
            { pages: pages, animated: pages > 1 }
          rescue ::Vips::Error
            { pages: 1, animated: false }
          end
      end
    end
  end
end
