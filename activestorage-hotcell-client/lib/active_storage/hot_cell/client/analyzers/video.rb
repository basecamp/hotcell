# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/analyzers/analyzing"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # Rails' VideoAnalyzer shells out to ffprobe inside the application process. Moving ffprobe into a
        # cell means this has to move with it, or an application that adopts hotcell still analyzes media in
        # its own process and cannot take ffprobe out of its image — the incomplete move for exactly the
        # media type a cell exists to isolate.
        #
        # Rails' exact video keys, sliced from the cell's superset. The cell already applied the rotation
        # swap and the anamorphic correction.
        class Video < ActiveStorage::Analyzer
          include Analyzing

          KEYS = %i[ width height duration angle display_aspect_ratio audio video ].freeze

          def self.accept?(blob)
            blob.video?
          end
        end
      end
    end
  end
end
