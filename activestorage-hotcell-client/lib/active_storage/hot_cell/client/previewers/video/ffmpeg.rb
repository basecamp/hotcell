# frozen_string_literal: true

require "active_storage/previewer/video_previewer"

require "active_storage/hot_cell/client/previewers/previewing"

module ActiveStorage
  module HotCell
    module Client
      module Previewers
        module Video
          # What Rails configures in `config.active_storage.previewers`, replacing VideoPreviewer.
          class Ffmpeg < ActiveStorage::Previewer::VideoPreviewer
            include Previewing

            self.client = Operations::Previewers::Video::Ffmpeg

            # blob.video? is the content-type predicate the superclass uses; ffmpeg_exists? is the part that
            # has to go.
            def self.accept?(blob)
              blob.video?
            end
          end

          FFmpeg = Ffmpeg
        end
      end
    end
  end
end
