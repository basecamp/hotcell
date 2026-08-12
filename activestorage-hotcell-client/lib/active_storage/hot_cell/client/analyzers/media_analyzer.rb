# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/analyzing"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # Rails' VideoAnalyzer and AudioAnalyzer shell out to ffprobe inside the application process. Moving
        # ffprobe into a cell means these have to move with it, or an application that adopts hotcell still
        # analyzes media in its own process and cannot take ffprobe out of its image — the incomplete move for
        # exactly the media type a cell exists to isolate.
        #
        # This holds what both share: a single ProbeMedia round trip. A subclass names which of Rails' two
        # shapes it presents, slicing the cell's superset to the keys its Rails analyzer writes.
        class MediaAnalyzer < ActiveStorage::Analyzer
          include Analyzing

          self.client = ProbeMedia
        end

        # `blob.video?` and Rails' exact video keys. The cell already applied the rotation swap and the
        # anamorphic correction, so this is a slice.
        class VideoAnalyzer < MediaAnalyzer
          KEYS = %i[ width height duration angle display_aspect_ratio audio video ].freeze

          def self.accept?(blob)
            blob.video?
          end
        end

        # `blob.audio?` and Rails' audio keys, minus `tags`: Rails writes raw container metadata into the
        # database, and the cell refuses it because those bytes are attacker-controlled.
        class AudioAnalyzer < MediaAnalyzer
          KEYS = %i[ duration bit_rate sample_rate ].freeze

          def self.accept?(blob)
            blob.audio?
          end
        end
      end
    end
  end
end
