# frozen_string_literal: true

require "test_helper"

class RetriesTest < ActiveStorageHotCellClientTest
  def test_it_teaches_the_jobs_to_retry_the_transient_class
    with_canned_response failed("capacity")

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "RetriesTest::FakeJob" ]

    assert_equal [ TemporarilyUnavailable ], FakeJob.retried.map(&:first)
  ensure
    FakeJob.forget
  end

  # The same policy the four jobs already declare for ActiveStorage::IntegrityError.
  def test_it_retries_the_way_rails_retries
    with_canned_response failed("capacity")

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "RetriesTest::FakeJob" ]

    assert_equal({ wait: :polynomially_longer, attempts: 10 }, FakeJob.retried.first.last)
  ensure
    FakeJob.forget
  end

  def test_it_does_not_teach_them_to_retry_the_permanent_class
    with_canned_response failed("unreadable")

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "RetriesTest::FakeJob" ]

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
