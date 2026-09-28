# frozen_string_literal: true

require "test_helper"

class PerformTest < YabedaHotCellTest
  def test_counts_a_successful_call_as_ok_and_measures_what_the_cell_spent
    answer HotCell::Response.new(result: {}, timing: { perform_ms: 250 })

    Anything.perform_in_hotcell [], [], {}

    assert_equal 1, requests(code: "ok", cause: "")
    assert_in_delta 0.25, perform_seconds
  end

  def test_counts_a_failure_under_its_own_code
    answer failed(code: "capacity")

    assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }

    assert_equal 1, requests(code: "capacity", cause: "")
  end

  # `killed` is one code and several verdicts: which limit the worker hit decides whether the file did it.
  # Every other code carries an empty cause, because a label that is sometimes absent is a separate series in
  # Prometheus, and a query by code would silently split.
  def test_counts_a_kill_under_its_cause
    answer failed(code: "killed", cause: "fsize")

    assert_raises(Unprocessable) { Anything.perform_in_hotcell [], [], {} }

    assert_equal 1, requests(code: "killed", cause: "fsize")
  end

  # A subscriber raises into whoever called instrument, so a bug here would otherwise arrive as a failed call.
  def test_a_metrics_bug_arrives_as_a_report_rather_than_as_a_failed_call
    ActiveSupport::Notifications.instrument("perform.hot_cell", cell: "test", perform_ms: "not a number") { }

    assert_equal [ NoMethodError ], @reported.map(&:class)
  end

  private
    def answer(response)
      HotCell.root = "/nowhere"
      register transport: CannedTransport.new(response)
    end

    def failed(code:, cause: nil)
      HotCell::Response.failed HotCell::Failure.new(code: code, cause: cause, message: "no"), timing: { perform_ms: 1 }
    end

    def requests(**tags)
      Yabeda::TestAdapter.instance.counters[Yabeda.hotcell.requests][{ **labels, **tags }]
    end

    def perform_seconds
      Yabeda::TestAdapter.instance.histograms[Yabeda.hotcell.perform][labels]
    end

    def labels
      { cell: "test", operation: "test.anything" }
    end

    class Anything < HotCell::Client
      hotcell "test"
      operation "test.anything"
    end
end
