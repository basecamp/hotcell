# frozen_string_literal: true

require "active_storage"

require "active_storage/hot_cell/client/version"
require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/transformations"
require "active_storage/hot_cell/client/transformer"
require "active_storage/hot_cell/client/image_analyzer"
require "active_storage/hot_cell/client/previewers"

module ActiveStorage
  module HotCell
    # Everything the application side defines lives under this, and everything the cell side defines lives under
    # ActiveStorage::HotCell::Server. Not a tidying convention: the two gems are never both loaded in production,
    # and a cell is forked from a process that may well have loaded this one — after which a shared name is a
    # superclass mismatch while the cell boots. Two namespaces make that impossible rather than avoided.
    module Client
      # The jobs that carry this work retry nothing a cell can transiently answer.
      #
      # TransformJob, AnalyzeJob, PreviewImageJob and CreateVariantsJob each declare `retry_on ActiveStorage::IntegrityError` and
      # nothing else, and ActiveJob has no default retry — so `capacity`, the one verdict whose entire purpose is
      # "try later", fails its job outright on the first attempt.
      #
      # This is opt-in rather than a railtie, because it reaches into an application's job classes and an
      # application should be able to see that happening in its own initializer.
      #
      #   ActiveStorage::HotCell::Client.retry_transient_failures!
      #
      # `:polynomially_longer` is deliberately not the default here. Its first retry lands around three seconds
      # later, and three seconds after a cell answered `capacity` it is still saturated — that is a thundering
      # herd rather than a backoff.
      JOBS = %w[
        ActiveStorage::TransformJob ActiveStorage::AnalyzeJob
        ActiveStorage::PreviewImageJob ActiveStorage::CreateVariantsJob
      ].freeze

      class << self
        def retry_transient_failures!(wait: 30.seconds, attempts: 5, jobs: JOBS)
          transient = TransformImage.cell.transient

          jobs.filter_map { |name| Object.const_get(name) if Object.const_defined?(name) }
              .each { |job| job.retry_on transient, wait: wait, attempts: attempts }
        end

        # Assert this rather than trusting that a configuration assignment took effect, because two obvious ways
        # of installing a transformer do not work and neither says so.
        #
        # Assigning ActiveStorage.variant_transformer from an initializer is silently overwritten during boot: the
        # engine assigns it from a config.after_initialize hook that runs later, and so does an application's own
        # after_initialize, since application railtie hooks run before the engine's. Prepending onto whatever
        # ActiveStorage.variant_transformer resolves to from a to_prepare block raises instead, because to_prepare
        # runs earlier still and the value is nil.
        #
        # So the only thing worth checking is the end state.
        def verify_installation!
          installed = ActiveStorage.variant_transformer

          return true if installed && (installed <= Transformer || installed.ancestors.include?(Transformer))

          raise ::HotCell::ConfigurationError,
                "ActiveStorage.variant_transformer is #{installed.inspect}, so variants are not going through a " \
                "cell. Set `config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformer`, and " \
                "note that assigning ActiveStorage.variant_transformer directly from an initializer is silently " \
                "overwritten by the engine later in boot."
        end
      end
    end
  end
end
