# Applying whatever transformation a signed URL happens to carry, which is what the vips path does today: Rails'
# Transformers::Vips overrides only #processor, so supported_image_processing_methods binds on ImageMagick alone.
require "active_storage/hot_cell/transform_image"
module ActiveStorage
  module HotCell
    class TransformImage
      private def operations_for(payload)
        (payload[:operations] || {}).filter_map { |name, argument| [ name, argument ] unless argument.nil? }
      end
    end
  end
end
