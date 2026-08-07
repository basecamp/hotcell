# frozen_string_literal: true

require "active_storage"

require "active_storage/hot_cell/client/version"
require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/transformers/vips"
require "active_storage/hot_cell/client/analyzers/image_analyzer/vips"
require "active_storage/hot_cell/client/previewers"
require "active_storage/hot_cell/client/railtie" if defined?(::Rails::Railtie)

module ActiveStorage
  module HotCell
    # Everything the application side defines lives under this, and everything the cell side defines lives under
    # ActiveStorage::HotCell::Server. Not a tidying convention: the two gems are never both loaded in production,
    # and a cell is forked from a process that may well have loaded this one — after which a shared name is a
    # superclass mismatch while the cell boots. Two namespaces make that impossible rather than avoided.
    module Client
      # These four jobs declare `retry_on ActiveStorage::IntegrityError` and nothing else, and ActiveJob does
      # not retry by default. They should retry the transient class too: `capacity` most obviously, and every
      # other transient verdict. The policy matches the one they already declare, so a cell failure and an
      # integrity failure back off the same way.
      #
      # Which of these classes exists depends on the Rails version, so a name that is not loaded is skipped.
      JOBS = %w[
        ActiveStorage::AnalyzeJob
        ActiveStorage::CreateVariantsJob
        ActiveStorage::PreviewImageJob
        ActiveStorage::TransformJob
      ].freeze

      RETRY = { wait: :polynomially_longer, attempts: 10 }.freeze

      class << self
        # The railtie calls this from a to_prepare block. Applied once at boot it would not survive a code
        # reload: a gem engine's app/jobs is in the reloadable autoloader, so these classes are discarded and
        # redefined, and the retry would silently disappear after the first file save in development.
        def retry_transient_failures!(jobs: JOBS)
          transient = TransformImage.cell.transient

          jobs.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }
              .each { |job| job.retry_on transient, **RETRY }
        end
      end
    end
  end
end
