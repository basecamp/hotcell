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
      # analyzer slices to Rails' `{ width, height }`. An input ImageMagick cannot decode exits `identify`
      # non-zero, which raises MiniMagick::Error, and the cell answers `unreadable`.
      class MagickAnalyzeImageOperation < MagickOperation
        operation "active_storage.analyze_image_imagemagick"

        limits deadline: 10, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 64

        # The orientation names identify reports for a quarter turn, matching Rails' rotated_image? on the
        # ImageMagick path.
        ROTATED = %w[ LeftTop RightTop RightBottom LeftBottom ].freeze

        def perform(inputs, _outputs)
          source, = inputs
          frames = identified(source.path)
          width, height, orientation = frames.first

          { **dimensions(width, height, orientation), pages: frames.size, animated: frames.size > 1,
            bytes: source.to_io.stat.size }
        end

        private
          # One `identify` run reports every frame's dimensions and orientation, where MiniMagick::Image's
          # accessors (`valid?`, `width`, `pages`) each spawn an identify of their own — four execs per
          # analysis, two of them decoding every frame.
          def identified(path)
            frames = MiniMagick.identify do |identify|
              identify.format "%w %h %[orientation]\n"
              identify << path
            end.lines.map(&:split)

            raise MiniMagick::Invalid, "ImageMagick does not recognise this as an image" if frames.empty?

            frames
          end

          def dimensions(width, height, orientation)
            if ROTATED.include?(orientation)
              { width: height.to_i, height: width.to_i }
            else
              { width: width.to_i, height: height.to_i }
            end
          end
      end
    end
  end
end
