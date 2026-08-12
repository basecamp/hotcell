# frozen_string_literal: true

require "active_storage"
require "active_storage/analyzer"
require "active_support/core_ext/class/attribute"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # What every analyzer here shares: one round trip to the cell, and the permanent-versus-transient
        # failure split. An analyzer names the client it asks and the KEYS it slices the cell's superset
        # down to — the cell knows more than Rails writes, and an extra key would change the shape of every
        # blob's metadata.
        #
        # **Which way `metadata` fails is the whole design of the method.** The built-in vips analyzer rescues
        # every Vips::Error and returns an empty hash, which Rails then merges with `analyzed: true` — so an
        # undecodable image is recorded as successfully analyzed, forever, and nothing ever re-enqueues
        # AnalyzeJob. That is right for a permanent verdict and catastrophic for a transient one.
        #
        # So a permanent failure follows the built-in behaviour and lets the blob be marked analyzed, with the
        # reason written to the log so it can be re-decided later against a newer library. A transient failure
        # is not rescued at all, which is what leaves the blob `analyzed: false` and eligible to be tried
        # again.
        module Analyzing
          def self.included(analyzer)
            analyzer.class_attribute :client, instance_accessor: false
          end

          def metadata
            measured.slice(*self.class::KEYS)
          rescue self.class.client.cell.permanent => error
            logger.warn "hotcell: #{blob.filename} could not be analyzed and will not be retried: #{error.message}"
            {}
          end

          private
            def measured
              download_blob_to_tempfile do |file|
                File.open(file.path, "rb") { |readable| self.class.client.perform_in_hotcell [ readable ], [] }
              end
            end
        end
      end
    end
  end
end
