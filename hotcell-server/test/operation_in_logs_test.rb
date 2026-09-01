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

  # The one line no worker is ever involved in: the worker died between the fork and the dispatch write, so
  # nothing has read the request and the supervisor is the side that answers it. It reads the request line
  # here, which it does nowhere else.
  def test_an_undispatchable_request_names_the_operation
    assert_equal "test.echo", undispatchable(sent: request_line("test.echo"))
  end

  # A caller that connected and has not sent yet, and a line still arriving, are the same case: nothing to
  # read without waiting, and waiting is what this must never do.
  def test_an_undispatchable_request_that_has_not_arrived_names_no_operation
    assert_nil undispatchable(sent: nil)
    assert_nil undispatchable(sent: %({"v":1,"op":"test.echo"))
  end

  # The property the whole dispatch design rests on: the supervisor hands a worker a connection whose bytes
  # and descriptors are still queued on it, because it has never called recvmsg. A read here to name the
  # operation would break that for the one path where a partially sent dispatch left a worker holding a copy
  # of this connection — so it peeks, with a bytes-only `recv` that installs no descriptors.
  def test_the_peek_leaves_the_request_and_its_descriptors_on_the_connection
    ours, theirs = UNIXSocket.pair(:STREAM)

    with_file("input bytes") do |path|
      reading(path) do |input|
        HotCell::Connection.new(theirs).send_message HotCell::Request.new(op: "test.echo", inputs: 1).to_line,
                                                     descriptors: [ input ]

        assert_equal "test.echo", supervisor.send(:peeked_op, HotCell::Connection.new(ours))

        # Asserted before the read rather than left to it: a peek that consumed the message leaves
        # `receive_message` blocking on a socket nobody will write to again, so without this the regression
        # is a hung suite rather than a failing test.
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

  private
    # A worker that died between the fork and the dispatch write, which is what `worker.undispatchable`
    # reports. Answers the operation the line named, or nil.
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

          logged(log_path, "worker.undispatchable").dig(:hotcell, :op)
        ensure
          (control + [ caller_side, cell_side ]).each { |socket| socket.close unless socket.closed? }
        end
      end
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
