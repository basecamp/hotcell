# frozen_string_literal: true

require "test_helper"

# Asserting values rather than that the collect block ran, because the namespace traps in the collector are
# silent: a bare `hotcell` records nothing, and a bare `HotCell` names this gem rather than the client.
class CollectTest < YabedaHotCellTest
  def test_publishes_a_running_cells_counters
    HotCell::TestCell.boot do |cell|
      HotCell.root = cell.socket_root
      register

      Yabeda.collect!
    end

    assert_equal 1, gauge(:up)
    assert_equal 0, gauge(:running)
    assert_equal 0, gauge(:queued)
    assert_equal 0, gauge(:queue_high_water)
    assert_equal 0, gauge(:cancelled)
    assert_kind_of Integer, gauge(:uptime_seconds)
    assert_kind_of Float, gauge(:start_time_seconds)
  end

  def test_publishes_when_the_cell_started
    HotCell.root = "/nowhere"
    register transport: CannedTransport.new(metrics(start_time_s: 1_760_000_000.25))

    Yabeda.collect!

    assert_equal 1_760_000_000.25, gauge(:start_time_seconds)
  end

  def test_a_cell_that_does_not_report_its_start_time_publishes_none
    HotCell.root = "/nowhere"
    register transport: CannedTransport.new(metrics)

    Yabeda.collect!

    refute_includes Yabeda::TestAdapter.instance.gauges[Yabeda.hotcell.start_time_seconds], { cell: "test" }
    assert_equal 41, gauge(:uptime_seconds)
    assert_equal 0, gauge(:killed, cause: "memory")
    assert_empty @reported
  end

  def test_publishes_kills_by_cause
    HotCell.root = "/nowhere"
    register transport: CannedTransport.new(metrics(killed_by: { memory: 5, deadline: 2 }))

    Yabeda.collect!

    assert_equal 5, gauge(:killed, cause: "memory")
    assert_equal 2, gauge(:killed, cause: "deadline")
  end

  # A restarted cell reports only the causes it has seen since boot, so a cause it omits has to read zero
  # rather than keep the count from before the restart.
  def test_a_kill_cause_the_cell_omits_reads_zero
    HotCell.root = "/nowhere"
    register transport: CannedTransport.new(metrics(killed_by: { memory: 5 }))
    Yabeda.collect!

    register transport: CannedTransport.new(metrics(killed_by: {}))
    Yabeda.collect!

    assert_equal 0, gauge(:killed, cause: "memory")
  end

  def test_a_cell_that_does_not_answer_is_down_rather_than_missing
    Dir.mktmpdir do |root|
      HotCell.root = root
      register

      Yabeda.collect!
    end

    assert_equal 0, gauge(:up)
    assert_nil gauge(:running)
  end

  def test_a_cell_with_no_root_publishes_nothing
    register

    Yabeda.collect!

    assert_nil gauge(:up)
  end

  def test_a_scrape_reports_a_misbehaving_cell_rather_than_failing
    HotCell.root = "/nowhere"
    register transport: BrokenTransport.new

    Yabeda.collect!

    assert_equal [ "the transport itself is broken" ], @reported.map(&:message)
  end

  private
    def metrics(**counters)
      HotCell::Response.new(result: { uptime_s: 41, running: 2, queued: 3, queue_high_water: 7, cancelled: 1,
                                      requests: {}, killed_by: {}, **counters })
    end
end
