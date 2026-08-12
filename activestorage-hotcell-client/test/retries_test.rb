# frozen_string_literal: true

require "test_helper"

class RetriesTest < ActiveStorageHotCellClientTest
  class VideoUnavailable < StandardError; end

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

  # The railtie calls this on every boot, including the boot where the application has bundled the gem and
  # not yet registered the cell. Raising there means adding the gem breaks boot, so rollout would take the
  # Gemfile change and the initializer in one deploy.
  def test_an_application_with_no_cell_registered_boots_rather_than_raising
    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "RetriesTest::FakeJob" ]

    assert_empty FakeJob.retried
  ensure
    FakeJob.forget
  end

  # Routing PreviewVideo to a cell of its own is the documented multi-cell arrangement, and each cell carries
  # its own transient class. The jobs have to retry every one of them, not only the class of the cell
  # TransformImage happens to name.
  def test_every_registered_cells_transient_class_is_retried
    with_canned_response failed("capacity")
    HotCell.register "video", permanent: Unprocessable, transient: VideoUnavailable
    ActiveStorage::HotCell::Client::PreviewVideo.hotcell "video"

    ActiveStorage::HotCell::Client.retry_transient_failures! jobs: [ "RetriesTest::FakeJob" ]

    assert_equal [ TemporarilyUnavailable, VideoUnavailable ], FakeJob.retried.map(&:first)
  ensure
    ActiveStorage::HotCell::Client::PreviewVideo.hotcell ActiveStorage::HotCell::Client::CELL
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
