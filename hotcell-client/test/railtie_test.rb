# frozen_string_literal: true

require "test_helper"
require "stringio"

begin
  require "rails"
rescue LoadError
  # The gem does not depend on Rails; railties rides in through the development bundle.
end

require "hot_cell/railtie" if defined?(Rails::Railtie)

# A Rails application initializes once per process, so this boots one and asserts everything the railtie
# does at boot.
class RailtieTest < HotCellClientTest
  def setup
    skip "railties is not in this bundle" unless defined?(Rails::Railtie)
    super
    @previous_logger = ActiveSupport::LogSubscriber.logger
    @root = Dir.mktmpdir("hotcell-railtie")
  end

  def teardown
    HotCell::LogSubscriber.detach_from :hot_cell
    ActiveSupport::LogSubscriber.logger = @previous_logger
    FileUtils.rm_rf @root if @root
    super
  end

  def test_boot_logs_each_call_to_the_rails_logger
    log = StringIO.new
    application(log).initialize!

    with_cell { Echo.perform_in_hotcell [], [], {} }

    lines = log.string.lines.grep(/HotCell \(\d+\.\dms\)/)
    assert_equal 1, lines.size, "expected one line for one call"
    assert_match '"operation":"test.echo"', lines.first
  end

  class Echo < HotCell::Client
    hotcell "test"
    operation "test.echo"
  end

  private
    def application(log)
      root = @root
      Class.new(Rails::Application) do
        config.eager_load = false
        config.root = root
        config.logger = Logger.new(log)
        config.active_support.deprecation = :silence
      end.instance
    end
end
