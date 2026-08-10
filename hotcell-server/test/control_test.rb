# frozen_string_literal: true

require "test_helper"

class ControlTest < HotCellServerTest
  def test_describe_reports_what_the_cell_carries_and_how_long_it_may_take
    TestCell.boot(concurrency: 3, queue_factor: 2, deadline: 45, queue_wait: 7) do |cell|
      result = assert_ok(cell.control("hotcell.describe")).result

      assert_equal HotCell::PROTOCOL_VERSION, result[:v]
      assert_equal 3, result[:concurrency]
      assert_equal 2, result[:queue_factor]
      assert_equal 45, result[:deadline]
      assert_equal 7, result[:queue_wait]
      assert_includes result[:operations], "test.uppercase"
    end
  end

  # Counts lag responses, and the wait is the assertion rather than a workaround. The worker writes the
  # response and the supervisor increments the counter when it later reads that worker's idle report — two
  # processes — so a caller can be holding its answer before the count exists. Anything reading these for
  # alarms should expect the same skew.
  def test_metrics_count_the_outcomes
    TestCell.boot do |cell|
      2.times { assert_ok cell.call("test.echo") }
      assert_failed "failed", cell.call("test.broken")
      assert_failed "unsupported", cell.call("test.nothing_like_it")

      wait_until(what: "the supervisor to count every request") do
        assert_ok(cell.control("hotcell.metrics")).result[:requests][:total] == 4
      end

      requests = assert_ok(cell.control("hotcell.metrics")).result[:requests]

      assert_equal 4, requests[:total]
      assert_equal 2, requests[:ok]
      assert_equal 1, requests[:failed]
      assert_equal 1, requests[:unsupported]
    end
  end

  def test_metrics_separate_a_decompression_bomb_from_a_slow_afternoon
    TestCell.boot(file_size: 4 * 1024 * 1024) do |cell|
      with_files do |source, destination|
        assert_failed "killed", cell.call("test.overflowing", inputs: [ source ], outputs: [ destination ],
                                                             payload: { megabytes: 8 }, timeout: 30),
                      limit: "fsize"
      end

      result = assert_ok(cell.control("hotcell.metrics")).result

      assert_equal 1, result[:killed_by][:fsize]
      assert_equal 0, result[:killed_by].fetch(:deadline, 0)
      assert_equal 1, result[:requests][:killed]
    end
  end

  # The one outcome that appears in no response, by definition: nobody is left to receive it. A cell quietly
  # doing work for callers who have gone away can only be seen from here.
  def test_metrics_count_a_caller_that_gave_up_before_the_cell_answered
    TestCell.boot(deadline: 1) do |cell|
      abandoned = cell.connect
      abandoned.send_message HotCell::Request.new(op: "test.blocking", payload: { seconds: 30 }).to_line
      wait_until(what: "the request to be running") do
        assert_ok(cell.control("hotcell.metrics")).result[:running].positive?
      end
      abandoned.close

      wait_until(what: "the deadline to kill the worker") do
        assert_ok(cell.control("hotcell.metrics")).result[:requests].fetch(:killed, 0).positive?
      end

      assert_equal 1, assert_ok(cell.control("hotcell.metrics")).result[:cancelled]
    end
  end

  def test_metrics_report_what_no_single_caller_can_see
    TestCell.boot(concurrency: 1, queue_factor: 4, deadline: 30) do |cell|
      blocker = cell.connect

      begin
        blocker.send_message HotCell::Request.new(op: "test.blocking", payload: { seconds: 0.6 }).to_line
        waiter = Thread.new { cell.call "test.echo", timeout: 20 }
        wait_until(what: "the queue to have something in it") do
          assert_ok(cell.control("hotcell.metrics")).result[:queue_high_water].positive?
        end

        result = assert_ok(cell.control("hotcell.metrics")).result
        assert_equal 1, result[:running]
        assert_operator result[:queue_high_water], :>=, 1

        assert_ok waiter.value
      ensure
        cell.answer blocker, 20
        blocker.close
      end
    end
  end

  # This is the test that justifies the second socket, and a single-socket implementation fails it: the work
  # queue is full and every worker is busy, and the scrape still answers. A metrics channel that goes quiet
  # under load reports the same thing as a dead cell.
  def test_control_answers_while_the_work_socket_is_saturated_and_its_queue_is_full
    TestCell.boot(concurrency: 1, queue_factor: 1, queue_wait: 20, deadline: 30) do |cell|
      held = 2.times.map { cell.connect }

      begin
        held.each do |connection|
          connection.send_message HotCell::Request.new(op: "test.blocking", payload: { seconds: 1.5 }).to_line
        end

        # An assertion inside wait_until raises on the first mismatch rather than retrying, so this waits on
        # the plain condition and asserts once it holds.
        wait_until(what: "the cell to saturate") { cell.call("test.echo").failure&.code == "capacity" }

        assert_ok cell.control("hotcell.describe")
        assert_ok cell.control("hotcell.metrics")
      ensure
        held.each { |connection| cell.answer connection, 25 }
        held.each(&:close)
      end
    end
  end

  def test_the_work_socket_does_not_answer_control_operations
    TestCell.boot do |cell|
      assert_failed "unsupported", cell.call("hotcell.metrics")
    end
  end

  def test_the_control_socket_does_not_answer_conversions
    TestCell.boot do |cell|
      failure = assert_failed "unsupported", cell.control("test.echo")

      assert_match "control.sock answers", failure.message
    end
  end

  def test_a_control_version_mismatch_is_transient
    TestCell.boot do |cell|
      response = cell.connect("control.sock") do |connection|
        connection.send_message HotCell::Request.new(op: "hotcell.describe", version: 99).to_line
        cell.answer connection
      end

      refute_predicate assert_failed("protocol", response), :terminal?
    end
  end

  # The hazard is a half-sent line rather than silence: the socket becomes readable once and then never
  # again, so a blocking read there would park the loop that every conversion depends on.
  def test_a_half_sent_control_message_cannot_stall_the_cell
    TestCell.boot do |cell|
      partial = cell.connect("control.sock")

      begin
        partial.socket.write '{"v":1,"op":"hotcell.desc'
        partial.socket.flush

        assert_ok cell.call("test.echo")
        assert_ok cell.control("hotcell.describe")
      ensure
        partial.close
      end
    end
  end

  def test_the_rest_of_a_half_sent_control_message_is_still_answered
    TestCell.boot do |cell|
      cell.connect("control.sock") do |connection|
        connection.socket.write '{"v":1,"op":"hotcell.desc'
        connection.socket.flush
        assert_ok cell.control("hotcell.describe")

        connection.socket.write %(ribe","inputs":0,"outputs":0,"payload":{}}\n)
        assert_ok cell.answer(connection)
      end
    end
  end

  def test_a_control_client_that_never_speaks_is_dropped_rather_than_held_forever
    TestCell.boot(control_deadline: 0.3) do |cell|
      silent = cell.connect("control.sock")

      begin
        wait_until(what: "the silent connection to be dropped") { cell.log_events("control.abandoned").any? }

        assert_ok cell.call("test.echo")
      ensure
        silent.close
      end
    end
  end

  def test_a_malformed_control_message
    TestCell.boot do |cell|
      response = cell.connect("control.sock") do |connection|
        connection.write_line "not json\n"
        cell.answer connection
      end

      assert_failed "invalid", response
    end
  end

  # This channel runs inside the loop every conversion depends on, so anything raised while answering a scrape
  # would stop the cell serving. :unlimited was the case that reached it: a Symbol is not JSON-native, so a
  # cell configured with it could not describe itself, and the attempt took the cell down.
  def test_a_cell_configured_for_persistent_workers_can_still_describe_itself
    TestCell.boot(reuse: :unlimited) do |cell|
      assert_equal "unlimited", assert_ok(cell.control("hotcell.describe")).result[:reuse]

      assert_ok cell.call("test.echo")
    end
  end

  def test_a_control_message_that_is_valid_json_but_not_an_object
    TestCell.boot do |cell|
      response = cell.connect("control.sock") do |connection|
        connection.write_line "[1,2,3]\n"
        cell.answer connection
      end

      assert_failed "invalid", response
      assert_ok cell.call("test.echo")
    end
  end
end
