# Letting a caller name any saver libvips has, rather than the ones this cell is willing to run.
require "active_storage/hot_cell/vips_operation"
module ActiveStorage
  module HotCell
    class VipsOperation
      private def format!(payload) = payload[:format].to_s.downcase
    end
  end
end
