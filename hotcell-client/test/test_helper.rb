# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "socket"

require "hot_cell/client"
require "hot_cell/test_support"

# The double ships from hotcell-server so that every consumer talks to the same one rather than writing its
# own. This suite is a consumer like any other.
require "hot_cell/test_cell"

require_relative "support/operations"

class HotCellClientTest < Minitest::Test
  include HotCell::TestSupport

  # Stand-ins for an application's own classes, which the gem must never name for itself.
  class Unprocessable < StandardError; end
  class TemporarilyUnavailable < StandardError; end

  def setup
    HotCell.reset_registrations!

    # Boot warnings are behaviour, and two tests assert them. Everywhere else they are noise.
    HotCell.logger = Logger.new(File::NULL)
  end

  def teardown
    HotCell.reset_registrations!
    HotCell.logger = nil
  end

  private
    # Boots a real cell and registers it, which is what an application's initializer does.
    def with_cell(name: "test", register: {}, **options)
      HotCell::TestCell.boot(name: name, **options) do |cell|
        HotCell.root = cell.socket_root
        HotCell.register name, permanent: Unprocessable, transient: TemporarilyUnavailable, **register

        yield cell
      end
    end

    def events_for(name = "perform.hot_cell")
      collected = []
      subscriber = ActiveSupport::Notifications.subscribe(name) { |event| collected << event }
      yield
      collected
    ensure
      ActiveSupport::Notifications.unsubscribe subscriber
    end
end
