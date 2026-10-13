# frozen_string_literal: true

require "test_helper"

begin
  require "rails"
  require "active_job/railtie"
rescue LoadError
  # The gem depends on activestorage alone; railties rides in through the development bundle.
end

require "active_storage/hot_cell/client/railtie" if defined?(Rails::Railtie)

# The railtie is the only thing that calls retry_transient_failures! in production. It must not load the jobs while
# the application initializes: loading one loads Active Job, which Rails' guard_load_hooks reports, or raises on
# here. And the retry must survive a code reload: a gem engine's app/jobs is in the reloadable autoloader, so the
# job classes are discarded and redefined, and a retry applied once silently disappears after the first file save
# in development. Booting a real (if minimal) Rails application is the only way to hold either fact.
class RailtieTest < ActiveStorageHotCellClientTest
  JOB = <<~RUBY
    class ActiveStorage::AnalyzeJob < ActiveJob::Base
    end
  RUBY

  def setup
    skip "railties is not in this bundle" unless defined?(Rails::Railtie)
    super
  end

  # One boot, because a Rails application initializes once per process, so everything the railtie does at boot
  # is asserted here. The job lives in the application's app/jobs so that the main autoloader manages it, as it
  # manages the Active Storage engine's, and the application raises on any framework loaded while it initializes.
  # The tool-argument settings are the same line an application writes for the in-process analyzer, and one is
  # left unset — nil in config, which must arrive as nothing rather than reach Shellwords. This application does
  # not load the Active Storage engine, so it creates the config namespace the engine would have.
  def test_boot_leaves_the_jobs_unloaded_and_applies_the_settings_and_each_load_of_a_job_applies_the_retry
    with_canned_response failed("capacity")
    application.config.active_storage = ActiveSupport::OrderedOptions.new
    application.config.active_storage.ffprobe_arguments = "-codec_whitelist h264,aac"

    application.initialize!

    assert ActiveStorage.autoload?(:AnalyzeJob), "boot loaded the job"
    assert_equal "-codec_whitelist h264,aac", ActiveStorage.ffprobe_arguments
    assert_equal "", ActiveStorage.video_preview_input_arguments

    assert_equal [ TemporarilyUnavailable.name ], ActiveStorage::AnalyzeJob.rescue_handlers.map(&:first),
                 "loading the job did not teach it to retry the transient class"

    application.reloader.reload!

    assert ActiveStorage.autoload?(:AnalyzeJob), "the reload did not unload the job"
    assert_equal [ TemporarilyUnavailable.name ], ActiveStorage::AnalyzeJob.rescue_handlers.map(&:first),
                 "a code reload lost the retry"
  ensure
    ActiveStorage.send :remove_const, :AnalyzeJob if ActiveStorage.const_defined?(:AnalyzeJob, false)
    ActiveStorage.ffprobe_arguments = ""
  end

  private
    # Named, because GlobalID's railtie, which Active Job's requires, takes its app name from the class name.
    def application
      @application ||= self.class.const_set(:Application, Class.new(Rails::Application) do
        config.eager_load = false
        config.enable_reloading = true
        config.action_on_early_load_hook = :raise
        config.root = Dir.mktmpdir("hotcell-railtie")
        config.logger = Logger.new(File::NULL)
        config.active_support.deprecation = :silence
      end).instance.tap do |application|
        FileUtils.mkdir_p application.root.join("app/jobs/active_storage")
        File.write application.root.join("app/jobs/active_storage/analyze_job.rb"), JOB
      end
    end
end
