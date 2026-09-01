# frozen_string_literal: true

require "test_helper"

# Which operation a line is about, on the five events that could not say. A cell runs several operations at
# once and they do not share limits, so an unattributed `killed cause=fsize` could not be acted on, and
# neither the response nor `hotcell_killed` could supply the name.
#
# The two sides learn it differently. A worker parses it out of the request it is serving. The supervisor
# never reads a request a worker is going to serve, so it learns the name from the worker's own report and
# holds it, which is what lets `worker.killed` name an operation the dead worker cannot report.
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

  # The line the issue was raised for. The worker is dead by the time it is written, so the name comes from
  # the report it sent before starting work.
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

  # A request that never parsed has no name to give, and the alternative is the previous request's, which
  # is worse than saying nothing because it reads as attributed.
  def test_a_request_that_never_parsed_names_no_operation
    TestCell.boot(max_requests_per_worker: 3, concurrency: 1) do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "invalid", cell.send_line("{not a request\n")

      wait_until(what: "both requests to be logged") { cell.log_events("request").size == 2 }

      assert_equal [ "test.echo", nil ], cell.log_events("request").map { |line| logged_op(line) }
    end
  end

  # The one line no worker is involved in: it died between the fork and the dispatch write, so nothing has
  # read the request and the supervisor answers it. This is the only place it reads a request line.
  def test_an_undispatchable_request_names_the_operation
    assert_equal "test.echo", undispatchable(sent: request_line("test.echo"))
  end

  # A caller that has not sent yet and a line still arriving are the same case: nothing to read without
  # waiting, and waiting is what this must never do.
  def test_an_undispatchable_request_that_has_not_arrived_names_no_operation
    assert_nil undispatchable(sent: nil)
    assert_nil undispatchable(sent: %({"v":1,"op":"test.echo"))
  end

  # The simple form of the property: peeking leaves the request and its descriptors where they were. The
  # test below puts it in the topology that makes it matter.
  def test_the_peek_leaves_the_request_and_its_descriptors_on_the_connection
    ours, theirs = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]

        assert_equal "test.echo", supervisor.send(:peeked_op, HotCell::Connection.new(ours))

        # A peek that consumed the message leaves `receive_message` blocking on a socket nobody will write
        # to again, so without this the regression is a hung suite rather than a failing test.
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

  # `send_message` can deliver the ancillary data and then fail on the rest of the line, so the supervisor
  # peeks a connection whose `SCM_RIGHTS` duplicate a worker already holds. Both halves have to survive on
  # that copy: the request bytes and the caller's descriptors.
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

  # The peek runs in the loop that enforces every request's deadline, so a blocking regression is a stuck
  # cell. Bounded here rather than left to the suite's own timeout to notice.
  def test_the_peek_does_not_wait_on_a_caller_that_has_not_sent
    ours, theirs = UNIXSocket.pair(:STREAM)
    connection = HotCell::Connection.new(ours)
    peeker = supervisor

    took = elapsed { assert_nil peeker.send(:peeked_op, connection) }

    assert_operator took, :<, 0.5, "the peek waited for a request that never came"
  ensure
    [ ours, theirs ].each { |socket| socket&.close unless socket&.closed? }
  end

  # Peeking retains no descriptor, which a `recvmsg` in its place would. Exactly that and no more: an
  # implementation that installed each and closed it before returning would pass. What must not happen is
  # the supervisor accumulating the caller's descriptors.
  def test_the_peek_retains_no_descriptors_in_the_supervisor
    ours, theirs = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]
        # Built before the count: each `supervisor` opens `File::NULL` for its null log, and three inside
        # the loop read exactly like three installed descriptors.
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

  # The end-to-end form of `Child#dispatched` clearing the name. The worker reported `test.echo`, then took
  # a request whose boot hook hangs before the operation is reported, and was killed there. The supervisor
  # never learned what it was running, and the line has to say so rather than name `test.echo`.
  def test_a_kill_before_the_worker_reports_names_no_operation
    TestCell.boot(deadline: 0.3, concurrency: 1, max_requests_per_worker: 3) do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "killed", cell.call("test.slow_boot", timeout: 20), cause: "deadline"

      assert_nil logged_op(wait_for_event(cell, "worker.killed").first)
    end
  end

  private
    # Reproduces the death between the fork and the dispatch write that `worker.undispatchable` reports.
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

    # `dig` answers nil for a key that is not there, so it cannot tell an unknown operation from a missing
    # field. This requires the field, and null.
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
