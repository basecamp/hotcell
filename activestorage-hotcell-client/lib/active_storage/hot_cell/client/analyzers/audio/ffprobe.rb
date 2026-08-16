# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/audio"
require "active_storage/hot_cell/client/analyzers/probing"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class Audio
          # What an application lists in `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Audio::Ffprobe, ... ]
          #
          # Shares the probe operation with the video analyzer; see Analyzers::Video::Ffprobe.
          class Ffprobe < Audio
            include Probing

            self.client = Operations::Analyzers::Media::Ffprobe
          end

          FFprobe = Ffprobe
        end
      end
    end
  end
end
