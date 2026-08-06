# frozen_string_literal: true

require "test_helper"

class InstallationTest < ActiveStorageHotCellClientTest
  def setup
    super
    @was = ActiveStorage.variant_transformer
  end

  def teardown
    ActiveStorage.variant_transformer = @was
    super
  end

  # Two obvious ways of installing a transformer do not work and neither says so. Assigning
  # ActiveStorage.variant_transformer from an initializer is silently overwritten during boot, because the engine
  # assigns it from a config.after_initialize hook that runs later — and so does an application's own
  # after_initialize, since application railtie hooks run before the engine's. Prepending onto whatever it
  # resolves to from a to_prepare block raises instead, because to_prepare runs earlier still and the value is
  # nil. So the only thing worth checking is the end state.
  def test_it_passes_when_the_transformer_is_the_one_rails_will_use
    ActiveStorage.variant_transformer = ActiveStorage::HotCell::Client::Transformer

    assert ActiveStorage::HotCell::Client.verify_installation!
  end

  def test_it_passes_for_a_subclass
    ActiveStorage.variant_transformer = Class.new(ActiveStorage::HotCell::Client::Transformer)

    assert ActiveStorage::HotCell::Client.verify_installation!
  end

  def test_it_says_so_when_the_configuration_never_took_effect
    ActiveStorage.variant_transformer = nil

    error = assert_raises(HotCell::ConfigurationError) { ActiveStorage::HotCell::Client.verify_installation! }
    assert_match "variants are not going through a cell", error.message
    assert_match "silently overwritten", error.message
  end

  def test_it_says_so_when_something_else_is_installed
    ActiveStorage.variant_transformer = ActiveStorage::Transformers::ImageProcessingTransformer

    assert_raises(HotCell::ConfigurationError) { ActiveStorage::HotCell::Client.verify_installation! }
  end

  # TransformJob, AnalyzeJob and PreviewImageJob declare retry_on ActiveStorage::IntegrityError and nothing else,
  # and ActiveJob has no default retry — so `capacity`, the one verdict whose entire purpose is "try later",
  # fails its job outright on the first attempt.
  def test_it_teaches_the_jobs_to_retry_the_transient_class
    with_canned_response failed("capacity")

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "InstallationTest::FakeJob" ]

    assert_equal [ TemporarilyUnavailable ], FakeJob.retried.map(&:first)
  ensure
    FakeJob.forget
  end

  def test_it_does_not_teach_them_to_retry_the_permanent_class
    with_canned_response failed("unreadable")

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "InstallationTest::FakeJob" ]

    refute_includes FakeJob.retried.map(&:first), Unprocessable
  ensure
    FakeJob.forget
  end

  # A job class an application has not loaded is skipped rather than raising, because which of them exist depends
  # on the Rails version.
  def test_a_job_that_is_not_loaded_is_skipped
    with_canned_response failed("capacity")

    assert_empty ActiveStorage::HotCell::Client.retry_transient_failures!(jobs: [ "NoSuchJob::Nowhere" ])
  end

  class FakeJob
    def self.retry_on(error, **options)
      retried << [ error, options ]
    end

    def self.retried
      @retried ||= []
    end

    def self.forget
      @retried = []
    end
  end
end
