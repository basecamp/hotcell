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
    def self.retry_on(*errors, **options)
      retried << [ errors, options ]
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

  # One boot, because a Rails application initializes once per process, so everything the railtie does at boot
  # is asserted here. The tool-argument settings are the same line an application writes for the in-process
  # analyzer, and one is left unset — nil in config, which must arrive as nothing rather than reach Shellwords.
  # This application does not load the Active Storage engine, so it creates the config namespace the engine
  # would have.
  def test_boot_applies_the_retry_and_the_settings_and_a_code_reload_reapplies_the_retry
    with_canned_response failed("capacity")
    ActiveStorage.const_set :AnalyzeJob, RecordingJob
    application.config.active_storage = ActiveSupport::OrderedOptions.new
    application.config.active_storage.ffprobe_arguments = "-codec_whitelist h264,aac"

    application.initialize!

    assert_equal [ TemporarilyUnavailable ], RecordingJob.retried.flat_map(&:first),
                 "boot did not teach the job to retry the transient class"
    assert_equal "-codec_whitelist h264,aac", ActiveStorage.ffprobe_arguments
    assert_equal "", ActiveStorage.video_preview_input_arguments

    RecordingJob.forget
    application.reloader.prepare!

    assert_equal [ TemporarilyUnavailable ], RecordingJob.retried.flat_map(&:first),
                 "a code reload lost the retry"
  ensure
    ActiveStorage.send :remove_const, :AnalyzeJob
    ActiveStorage.ffprobe_arguments = ""
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
