# Dropping `page: 0`, so one thumbnail of a hundred-frame GIF decodes all hundred frames.
require "active_storage/hot_cell/server/transform_image"
module ActiveStorage
  module HotCell
    module Server
      class TransformImage
        private def loader_for(_payload) = { n: -1 }
      end
    end
  end
end
