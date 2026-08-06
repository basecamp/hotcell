# Answering accept? the way the built-in previewers do, by shelling out to see whether the binary is installed.
# Once the converters leave the application image both answer false, previewable? goes false with them, and
# previews stop existing with no exception and no alert.
require "active_storage/hot_cell/client/previewers"
module ActiveStorage
  module HotCell
    module Client
      class PdfPreviewer
        def self.accept?(blob) = pdf?(blob.content_type) && mutool_exists?
      end

      class VideoPreviewer
        def self.accept?(blob) = blob.video? && ffmpeg_exists?
      end
    end
  end
end
