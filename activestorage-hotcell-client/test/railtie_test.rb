# frozen_string_literal: true

require "test_helper"

begin
  require "rails"
rescue LoadError
  # The gem depends on activestorage alone; railties rides in through the development bundle.
end

require "active_storage/hot_cell/client/railtie" if defined?(Rails::Railtie)

# The railtie is the only thing that calls retry_transient_failures! in production, and it must do so from
# to_prepare: a gem engine's app/jobs is in the reloadable autoloader, so the job classes are discarded and
# redefined on every code reload, and a retry applied once at boot silently disappears after the first file
# save in development. Booting a real (if minimal) Rails application is the only way to hold either fact.
class RailtieTest < ActiveStorageHotCellClientTest
  class RecordingJob
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

  def setup
    skip "railties is not in this bundle" unless defined?(Rails::Railtie)
    super
  end

  def test_boot_applies_the_retry_and_a_code_reload_reapplies_it
    with_canned_response failed("capacity")
    ActiveStorage.const_set :AnalyzeJob, RecordingJob

    application.initialize!

    assert_equal [ TemporarilyUnavailable ], RecordingJob.retried.map(&:first),
                 "boot did not teach the job to retry the transient class"

    RecordingJob.forget
    application.reloader.prepare!

    assert_equal [ TemporarilyUnavailable ], RecordingJob.retried.map(&:first),
                 "a code reload lost the retry"
  ensure
    ActiveStorage.send :remove_const, :AnalyzeJob
    RecordingJob.forget
  end

  private
    def application
      @application ||= Class.new(Rails::Application) do
        config.eager_load = false
        config.root = Dir.mktmpdir("hotcell-railtie")
        config.logger = Logger.new(File::NULL)
        config.active_support.deprecation = :silence
      end.instance
    end
end
