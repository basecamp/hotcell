# frozen_string_literal: true

require "test_helper"

# Which operation a line is about, on the four events that could not say.
#
# A cell runs several operations at once and they do not share limits, so `killed cause=fsize` on a host
# serving three PDF operations named none of them — and nothing else could, because the app-side response
# carries no operation either and `hotcell_killed` is tagged `cell` and `cause` only. There was no join
# available in the logs or in the metrics.
#
# The two sides learn the name differently. A worker parses it out of the request it is serving. The
# supervisor never reads a request — that is what lets it dispatch a connection whose descriptors are still
# queued on it — so it learns the name from the worker's own report, and holds it because a killed worker
# cannot report its own death.
class OperationInLogsTest < HotCellServerTest
  def test_a_request_line_names_the_operation
    TestCell.boot do |cell|
      assert_ok cell.call("test.echo")

      assert_equal "test.echo", wait_for_event(cell, "request").first.dig(:hotcell, :op)
    end
  end

  # The worker is holding the request when the caller goes, so this is the one line it can still attribute.
  def test_an_abandoned_request_names_the_operation
    TestCell.boot do |cell|
      connection = cell.connect
      connection.send_message request_line("test.blocking", seconds: 0.5)
      connection.close

      assert_equal "test.blocking", wait_for_event(cell, "request.abandoned").first.dig(:hotcell, :op)
    end
  end

  # The line the issue was raised for. The worker is dead by the time this is written, so the name comes
  # from the report it sent before it started work.
  def test_a_killed_worker_is_attributed_to_the_operation_it_was_running
    TestCell.boot(deadline: 0.3, concurrency: 1) do |cell|
      assert_failed "killed", cell.call("test.uninterruptible", timeout: 20), cause: "deadline"

      assert_equal "test.uninterruptible", wait_for_event(cell, "worker.killed").first.dig(:hotcell, :op)
    end
  end

  def test_a_crashed_worker_names_the_operation_it_was_running
    TestCell.boot do |cell|
      cell.call "test.fatal"

      assert_equal "test.fatal", wait_for_event(cell, "worker.crashed").first.dig(:hotcell, :op)
    end
  end

  # A request that never parsed has no name to give, and the alternative to saying nothing is saying the
  # name of the request before it — which is worse than an unattributed line, because it reads as attributed.
  def test_a_request_that_never_parsed_names_no_operation
    TestCell.boot(max_requests_per_worker: 3, concurrency: 1) do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "invalid", cell.send_line("{not a request\n")

      wait_until(what: "both requests to be logged") { cell.log_events("request").size == 2 }

      assert_equal [ "test.echo", nil ], cell.log_events("request").map { |line| line.dig(:hotcell, :op) }
    end
  end
end
