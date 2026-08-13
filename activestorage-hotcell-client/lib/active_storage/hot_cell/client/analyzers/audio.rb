# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/analyzers/analyzing"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # Rails' AudioAnalyzer, moved to the cell the way the video analyzer is.
        #
        # Rails' audio keys, minus `tags`: Rails writes raw container metadata into the database, and the
        # cell refuses it because those bytes are attacker-controlled.
        class Audio < ActiveStorage::Analyzer
          include Analyzing

          KEYS = %i[ duration bit_rate sample_rate ].freeze

          def self.accept?(blob)
            blob.audio?
          end
        end
      end
    end
  end
end
