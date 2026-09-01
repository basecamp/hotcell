# frozen_string_literal: true

require "test_helper"

# Which operation a line is about, on the five events that could not say.
class OperationInLogsTest < HotCellServerTest
  def test_a_request_line_names_the_operation
    TestCell.boot do |cell|
      assert_ok cell.call("test.echo")

      assert_equal "test.echo", wait_for_event(cell, "request").first.dig(:hotcell, :op)
    end
  end

  def test_an_abandoned_request_names_the_operation
    TestCell.boot do |cell|
      connection = cell.connect
      connection.send_message request_line("test.blocking", seconds: 0.5)
      connection.close

      assert_equal "test.blocking", wait_for_event(cell, "request.abandoned").first.dig(:hotcell, :op)
    end
  end

  # The worker is dead by the time this line is written, so the name comes from its earlier report.
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

  # The alternative to saying nothing is the previous request's name, which reads as attributed.
  def test_a_request_that_never_parsed_names_no_operation
    TestCell.boot(max_requests_per_worker: 3, concurrency: 1) do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "invalid", cell.send_line("{not a request\n")

      wait_until(what: "both requests to be logged") { cell.log_events("request").size == 2 }

      assert_equal [ "test.echo", nil ], cell.log_events("request").map { |line| logged_op(line) }
    end
  end

  # The supervisor answers this one itself, and it is the only place it reads a request line.
  def test_an_undispatchable_request_names_the_operation
    assert_equal "test.echo", undispatchable(sent: request_line("test.echo"))
  end

  # A caller that has not sent yet and a line still arriving are the same case: nothing to read.
  def test_an_undispatchable_request_that_has_not_arrived_names_no_operation
    assert_nil undispatchable(sent: nil)
    assert_nil undispatchable(sent: %({"v":1,"op":"test.echo"))
  end

  def test_the_peek_leaves_the_request_and_its_descriptors_on_the_connection
    ours, theirs = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]

        assert_equal "test.echo", supervisor.send(:peeked_op, HotCell::Connection.new(ours))

        # Without this a consuming peek hangs the suite here instead of failing.
        assert ours.wait_readable(1), "the peek took the request off the connection"

        line, descriptors = HotCell::Connection.new(ours).receive_message
        assert_equal "test.echo", HotCell::Request.parse(line).op
        assert_equal 1, descriptors.size, "the peek took the caller's descriptors off the connection"
        assert_equal "input bytes", descriptors.first.read
        descriptors.each(&:close)
      end
    end
  ensure
    [ ours, theirs ].each { |socket| socket&.close unless socket&.closed? }
  end

  # The topology that makes the peek matter: a partial `send_message` leaves a worker holding a duplicate,
  # and both the request bytes and the caller's descriptors have to survive on it.
  def test_the_peek_leaves_the_request_for_a_worker_holding_a_duplicate_of_the_connection
    ours, theirs = UNIXSocket.pair(:STREAM)
    to_worker, worker_side = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]
        HotCell::Connection.new(to_worker).send_message %({"queued_ms":0}\n), descriptors: [ ours ]

        assert_equal "test.echo", supervisor.send(:peeked_op, HotCell::Connection.new(ours))

        _, passed = HotCell::Connection.new(worker_side).receive_message(limit: HotCell::Worker::DISPATCH_BYTES)
        duplicate = passed.first
        assert duplicate, "the connection never reached the worker"

        assert duplicate.wait_readable(1), "the peek took the request off the worker's copy"
        line, descriptors = HotCell::Connection.new(duplicate).receive_message
        assert_equal "test.echo", HotCell::Request.parse(line).op
        assert_equal 1, descriptors.size, "the peek took the caller's descriptors off the worker's copy"
        assert_equal "input bytes", descriptors.first.read

        (descriptors + passed).each { |io| io.close unless io.closed? }
      end
    end
  ensure
    [ ours, theirs, to_worker, worker_side ].each { |socket| socket&.close unless socket&.closed? }
  end

  # The peek runs in the loop enforcing every request's deadline, so a blocking regression is a stuck cell.
  def test_the_peek_does_not_wait_on_a_caller_that_has_not_sent
    ours, theirs = UNIXSocket.pair(:STREAM)
    connection = HotCell::Connection.new(ours)
    peeker = supervisor

    took = elapsed { assert_nil peeker.send(:peeked_op, connection) }

    assert_operator took, :<, 0.5, "the peek waited for a request that never came"
  ensure
    [ ours, theirs ].each { |socket| socket&.close unless socket&.closed? }
  end

  # Exactly this and no more: an implementation that installed each descriptor and closed it before
  # returning would pass. What must not happen is the supervisor accumulating them.
  def test_the_peek_retains_no_descriptors_in_the_supervisor
    ours, theirs = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]
        # Built before the count: each `supervisor` opens `File::NULL`, which reads like an install.
        peeker = supervisor
        connection = HotCell::Connection.new(ours)
        before = open_descriptors

        3.times { peeker.send :peeked_op, connection }

        assert_equal before, open_descriptors, "the supervisor kept the caller's descriptors"
      end
    end
  ensure
    [ ours, theirs ].each { |socket| socket&.close unless socket&.closed? }
  end

  # The worker reported `test.echo`, then took one whose boot hook hangs before the operation is reported.
  # The supervisor never learned what it was killing, and the line must not fall back to `test.echo`.
  def test_a_kill_before_the_worker_reports_names_no_operation
    TestCell.boot(deadline: 0.3, concurrency: 1, max_requests_per_worker: 3) do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "killed", cell.call("test.slow_boot", timeout: 20), cause: "deadline"

      assert_nil logged_op(wait_for_event(cell, "worker.killed").first)
    end
  end

  private
    def undispatchable(sent:)
      Dir.mktmpdir "hotcell-undispatchable" do |directory|
        log_path = File.join(directory, "cell.log")
        control = UNIXSocket.pair(:STREAM)
        caller_side, cell_side = UNIXSocket.pair(:STREAM)
        child = HotCell::Supervisor::Child.build slot: HotCell::Slot.build(directory, 0), pid: Process.pid,
                                                 control: HotCell::Connection.new(control.first), deadline: 30
        control.last.close
        caller_side.write sent if sent

        begin
          refute supervisor(directory: directory, log_path: log_path)
            .send(:dispatch, child, HotCell::Connection.new(cell_side), 0),
                 "the dispatch was expected to fail"

          logged_op logged(log_path, "worker.undispatchable")
        ensure
          (control + [ caller_side, cell_side ]).each { |socket| socket.close unless socket.closed? }
        end
      end
    end

    # `dig` cannot tell an unknown operation from a missing field. This requires the field, and null.
    def logged_op(line)
      assert line.fetch(:hotcell).key?(:op), "the line carries no op field at all"

      line.dig(:hotcell, :op)
    end

    def supervisor(directory: Dir.mktmpdir("hotcell-supervisor"), log_path: nil)
      log = log_path ? HotCell::Log.new(File.open(log_path, "w")) : HotCell::Log.null
      HotCell::Supervisor.new directory: directory, log: log
    end

    def logged(path, event)
      line = File.readlines(path).map { |written| JSON.parse written, symbolize_names: true }
                 .find { |written| written.dig(:event, :action) == event }

      line or flunk "no #{event} line was written"
    end
end
