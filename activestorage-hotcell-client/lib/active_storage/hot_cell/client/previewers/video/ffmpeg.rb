# frozen_string_literal: true

require "active_storage/previewer/video_previewer"

require "active_storage/hot_cell/client/previewers/previewing"
require "active_storage/hot_cell/client/tool_arguments"

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

            private
              # `config.active_storage.video_preview_input_arguments`, which Rails splices before `-i`, carried
              # to the cell so it can do the same. Split here, the way Rails splits it, and omitted when empty.
              def payload
                ToolArguments.payload(:input_arguments, ActiveStorage.video_preview_input_arguments)
              end
          end

          FFmpeg = Ffmpeg
        end
      end
    end
  end
end
