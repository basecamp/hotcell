# Rescuing everything, the way the built-in vips analyzer does. It returns {} for any Vips::Error, Rails merges
# that with analyzed: true, and an image that failed because a cell was restarting is recorded as successfully
# analyzed forever with nothing to re-enqueue it.
require "active_storage/hot_cell/image_analyzer"
module ActiveStorage
  module HotCell
    class ImageAnalyzer
      def metadata
        measured.slice(:width, :height)
      rescue StandardError
        {}
      end
    end
  end
end
