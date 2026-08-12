# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # Rails' VideoAnalyzer and AudioAnalyzer shell out to ffprobe inside the application process. Moving
        # ffprobe into a cell means these have to move with it, or an application that adopts hotcell still
        # analyzes media in its own process and cannot take ffprobe out of its image — the incomplete move for
        # exactly the media type a cell exists to isolate.
        #
        # This holds what both share: a single ProbeMedia round trip, and the permanent-versus-transient split
        # the image analyzer uses. A subclass names which of Rails' two shapes it presents. The cell returns a
        # superset; each subclass slices it to the keys its Rails analyzer writes, which is what keeps this a
        # drop-in — an extra key would change the shape of every blob's metadata.
        class MediaAnalyzer < ActiveStorage::Analyzer
          # A permanent verdict follows the built-in behaviour: the reason is logged and the blob is marked
          # analyzed rather than retried forever. A transient failure is not rescued, so the blob stays
          # `analyzed: false` and eligible to be tried again once the cell recovers.
          def metadata
            probed.slice(*self.class::KEYS)
          rescue ProbeMedia.cell.permanent => error
            logger.warn "hotcell: #{blob.filename} could not be analyzed and will not be retried: #{error.message}"
            {}
          end

          private
            def probed
              download_blob_to_tempfile do |file|
                File.open(file.path, "rb") { |readable| ProbeMedia.perform_in_hotcell [ readable ], [] }
              end
            end
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
