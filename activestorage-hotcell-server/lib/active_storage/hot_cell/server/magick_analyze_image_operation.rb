# frozen_string_literal: true

require "active_storage/hot_cell/server/magick_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick` does, moved out of the application: width and
      # height from `identify`, with the dimensions swapped when the stored orientation is a quarter turn, the
      # way the shared image analyzer does it.
      #
      # The result is a superset — pages and animation, which the vips analyzer also reports — that the client
      # analyzer slices to Rails' `{ width, height }`. An input ImageMagick cannot decode raises
      # MiniMagick::Error or fails `valid?`, and either way the cell answers `unreadable`.
      class MagickAnalyzeImageOperation < MagickOperation
        operation "active_storage.analyze_image_imagemagick"

        limits deadline: 10, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 64

        # The orientation names identify reports for a quarter turn, matching Rails' rotated_image? on the
        # ImageMagick path.
        ROTATED = %w[ LeftTop RightTop RightBottom LeftBottom ].freeze

        def perform(inputs, _outputs)
          source, = inputs
          image = MiniMagick::Image.new(source.path)
          refuse_unreadable! unless image.valid?

          { **dimensions_of(image), **frames_of(image), bytes: source.to_io.stat.size }
        end

        private
          def dimensions_of(image)
            if ROTATED.include?(image["%[orientation]"])
              { width: image.height, height: image.width }
            else
              { width: image.width, height: image.height }
            end
          end

          def frames_of(image)
            pages = image.pages.size
            { pages: pages, animated: pages > 1 }
          rescue MiniMagick::Error
            { pages: 1, animated: false }
          end

          def refuse_unreadable!
            raise MiniMagick::Invalid, "ImageMagick does not recognise this as an image"
          end
      end
    end
  end
end
