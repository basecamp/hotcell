# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/video"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class Video
          # What an application lists in `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Video::Ffprobe, ... ]
          #
          # One probe operation serves this and the audio analyzer: ffprobe reports both stream kinds in one
          # pass, and each analyzer slices the shared result to its own keys.
          class Ffprobe < Video
            self.client = Operations::Analyzers::Media::Ffprobe
          end

          FFprobe = Ffprobe
        end
      end
    end
  end
end
