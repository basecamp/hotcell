# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "logger"

require "yabeda/hot_cell"
require "yabeda/testing"
require "hot_cell/test_cell"

Yabeda::HotCell.install!
Yabeda.configure!

class YabedaHotCellTest < Minitest::Test
  # Stand-ins for an application's own classes, which the gem must never name for itself.
  class Unprocessable < StandardError; end
  class TemporarilyUnavailable < StandardError; end

  def setup
    HotCell.reset_registrations!
    HotCell.logger = Logger.new(File::NULL)
    Yabeda::TestAdapter.instance.reset!
    ActiveSupport.error_reporter.subscribe(@reported = ReportedErrors.new)
  end

  def teardown
    ActiveSupport.error_reporter.unsubscribe @reported
    HotCell.reset_registrations!
    HotCell.logger = nil
  end

  private
    def register(**options)
      HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable, **options
    end

    def gauge(metric, **tags)
      Yabeda::TestAdapter.instance.gauges[Yabeda.hotcell.public_send(metric)][{ cell: "test", **tags }]
    end

    class ReportedErrors < Array
      def report(error, **)
        self << error
      end
    end

    class CannedTransport
      def initialize(response)
        @response = response
      end

      def call(_cell, _line, _descriptors, socket: nil, timeout: nil)
        @response
      end
    end

    class BrokenTransport
      def call(_cell, _line, _descriptors, socket: nil, timeout: nil)
        raise "the transport itself is broken"
      end
    end
end
