# frozen_string_literal: true

require "test_helper"

class SchedulingTest < HotCellServerTest
  def setup
    unless Fixtures::Uninterruptible.blocks_through_a_timeout?
      skip "Integer#** is interruptible on this Ruby, so it no longer stands in for a C extension"
    end
  end

  # Two things are being tested. That the supervisor kills an overdue worker at all, and that it does so
  # promptly, with no other request needed to trigger the reap. A supervisor that only reaped at the top of
  # its accept loop would leave this caller waiting out its whole timeout, so the naive implementation
  # fails by hanging rather than by answering wrongly.
  def test_a_worker_pinned_where_ruby_cannot_interrupt_it_is_killed_at_the_deadline
    TestCell.boot(deadline: 1) do |cell|
      response = nil
      took = elapsed { response = cell.call("test.uninterruptible", timeout: 20) }

      failure = assert_failed "killed", response, limit: "deadline"
      assert_equal "KILL", failure.signal
      assert_operator took, :<, 4, "the work itself takes 6.7s, so this was not a kill"

      # A killed worker cannot report anything, so the supervisor fills this in from fork to reap. It is an
      # upper bound rather than a measurement, and it is worth having: killed at 30s and killed at 0.2s are
      # different bugs.
      assert_operator response.timing[:perform_ms], :>=, 900
    end
  end

  # A deadline breach is as much a property of the load as of the input. Treating it as terminal would mean
  # a busy afternoon permanently condemns whatever was uploaded during it.
  # One kill per breach. Killing leaves the child busy, because the supervisor still holds the connection it
  # has to answer on, so a child that stayed a timer source would be re-killed and re-logged on every pass of
  # the loop until the reap — a synchronous stdout write each time, in the loop enforcing every other
  # request's deadline.
  def test_a_deadline_kill_is_sent_once_rather_than_on_every_pass
    TestCell.boot(deadline: 0.2, concurrency: 1) do |cell|
      assert_failed "killed", cell.call("test.uninterruptible", timeout: 20), limit: "deadline"
      wait_until(what: "the worker to be reaped") { cell.log_events("worker.reaped").any? }

      assert_equal 1, cell.log_events("worker.deadline").size,
                   "expected one kill for one breach"
    end
  end

  # The deadline has to reach what the request started, not only the Ruby process that started it. A
  # converter is a grandchild — the worker spawns it — and killing the worker alone left it running, adopted
  # by the supervisor as pid 1, with no deadline and nothing watching it.
  def test_a_deadline_kills_what_the_worker_started_too
    with_file do |path|
      ENV["HOTCELL_SPAWNED_PID_PATH"] = path

      TestCell.boot(deadline: 0.3, concurrency: 1) do |cell|
        assert_failed "killed", cell.call("test.spawns", timeout: 20), limit: "deadline"

        wait_until(what: "the worker to report what it spawned") { File.size(path).positive? }
        spawned = Integer(File.read(path))

        wait_until(what: "the spawned process to be gone") { !alive?(spawned) }
      end
    end
  ensure
    ENV.delete "HOTCELL_SPAWNED_PID_PATH"
  end

  def test_a_deadline_breach_is_not_terminal
    TestCell.boot(deadline: 1) do |cell|
      refute_predicate assert_failed("killed", cell.call("test.uninterruptible", timeout: 20)), :terminal?
    end
  end

  # The supervisor never reads a request, so it cannot know that this operation asked for one second when
  # the cell allows twenty. The worker is the only thing that knows, and it says so before it touches an
  # untrusted byte.
  def test_an_operation_may_ask_for_a_shorter_deadline_than_the_cell_allows
    TestCell.boot(deadline: 20) do |cell|
      took = elapsed { assert_failed "killed", cell.call("test.impatient", timeout: 20), limit: "deadline" }

      assert_operator took, :<, 4, "the cell's 20s deadline was used instead of the operation's 1s"
    end
  end

  # Invariant 6: an operation cannot exceed its cell's limits, whatever it declares.
  def test_an_operation_asking_for_a_longer_deadline_is_clamped_to_the_cell
    TestCell.boot(deadline: 1) do |cell|
      took = elapsed { assert_failed "killed", cell.call("test.patient", timeout: 20), limit: "deadline" }

      assert_operator took, :<, 4, "the operation's 300s deadline was not clamped to the cell's 1s"
    end
  end

  # The deadline is per request rather than per worker life. Three requests of six tenths of a second each
  # all fit inside a one second deadline, and none of them fits inside what is left of a cumulative one.
  def test_a_reused_worker_gets_the_whole_deadline_again_on_its_next_request
    TestCell.boot(deadline: 1, reuse: 3, concurrency: 1) do |cell|
      pids = 3.times.map do
        assert_ok(cell.call("test.blocking", payload: { seconds: 0.6 }, timeout: 20)).result[:pid]
      end

      assert_equal 1, pids.uniq.size, "expected one worker to serve all three"
    end
  end

  def test_at_reuse_three_a_worker_serves_three_requests_and_the_fourth_lands_on_a_new_one
    TestCell.boot(reuse: 3, concurrency: 1) do |cell|
      pids = 4.times.map { assert_ok(cell.call("test.whoami")).result[:pid] }

      assert_equal 1, pids.first(3).uniq.size, "expected one worker for the first three: #{pids.inspect}"
      refute_includes pids.first(3), pids.last
    end
  end

  # reuse: 1 is the only value where a request cannot reach another request.
  def test_at_reuse_one_every_request_gets_a_fresh_worker
    TestCell.boot(reuse: 1, concurrency: 1) do |cell|
      pids = 3.times.map { assert_ok(cell.call("test.whoami")).result[:pid] }

      assert_equal 3, pids.uniq.size, "expected three distinct workers: #{pids.inspect}"
    end
  end

  def test_a_reused_worker_keeps_its_slot_and_therefore_its_home
    TestCell.boot(reuse: 2, concurrency: 1) do |cell|
      homes = 2.times.map { assert_ok(cell.call("test.whoami")).result[:home] }

      assert_equal 1, homes.uniq.size
      assert_equal File.join(cell.workspace, "0", "home"), homes.first
    end
  end

  def test_workers_running_at_once_get_different_slots_and_therefore_different_homes
    TestCell.boot(concurrency: 2, queue_factor: 2) do |cell|
      homes = in_parallel(2) { assert_ok(cell.call("test.blocking", payload: { seconds: 0.4 }, timeout: 20)) }
        .map { |response| response.result[:pid] }

      assert_equal 2, homes.uniq.size, "expected two workers to run at once"
    end
  end

  # Saturation shows up as latency before it shows up as failure. At concurrency 2 and queue_factor 1 the
  # cell runs two and holds two waiting; the fifth is refused. A cell that only ever refused would go from
  # healthy to erroring with nothing in between and nothing to alarm on.
  def test_the_queue_absorbs_a_burst_and_the_overflow_is_refused
    TestCell.boot(concurrency: 2, queue_factor: 1, queue_wait: 20, deadline: 30) do |cell|
      connections = 5.times.map { cell.connect }

      begin
        connections.first(2).each do |connection|
          connection.send_message request_line("test.blocking", seconds: 0.5)
        end
        connections.drop(2).each { |connection| connection.send_message request_line("test.echo") }

        responses = connections.map { |connection| cell.answer connection, 25 }

        assert responses.first(2).all?(&:ok?), "expected the first two to run"
        assert_predicate responses[2], :ok?, "expected the third to be queued and then run: #{responses[2].failure}"
        assert_predicate responses[3], :ok?, "expected the fourth to be queued and then run: #{responses[3].failure}"
        assert_failed "capacity", responses[4]

        assert_operator responses[2].timing[:queued_ms], :>, 0, "a queued request must report its wait"
      ensure
        connections.each(&:close)
      end
    end
  end

  def test_a_refusal_is_transient_so_a_restarting_cell_never_condemns_a_document
    TestCell.boot(concurrency: 1, queue_factor: 0, deadline: 30) do |cell|
      connection = cell.connect

      begin
        connection.send_message request_line("test.blocking", seconds: 0.4)
        wait_until(what: "the first worker to start") { cell.log_events("worker.forked").any? }

        refute_predicate assert_failed("capacity", cell.call("test.echo")), :terminal?
      ensure
        cell.answer connection, 20
        connection.close
      end
    end
  end

  # Without queue_wait a queued connection waits until the client's own timeout fires, so the client
  # reports a transport error and the cell's capacity verdict is never delivered — making the code the
  # queue exists to surface unreachable exactly when the cell is saturated. thimble shipped without this
  # and documented the symptom.
  def test_a_connection_that_waits_too_long_is_told_so_by_the_cell_rather_than_timing_out
    TestCell.boot(concurrency: 1, queue_factor: 4, queue_wait: 0.3, deadline: 30) do |cell|
      blocker = cell.connect

      begin
        blocker.send_message request_line("test.blocking", seconds: 3)
        wait_until(what: "the first worker to start") { cell.log_events("worker.forked").any? }

        took = elapsed { assert_failed "capacity", cell.call("test.echo", timeout: 20) }

        assert_operator took, :<, 2, "expected the cell to answer at queue_wait rather than after the block"
      ensure
        cell.answer blocker, 20
        blocker.close
      end
    end
  end

  private
    def request_line(op, **payload)
      HotCell::Request.new(op: op, payload: payload).to_line
    end

    def in_parallel(count, &block)
      count.times.map { Thread.new(&block) }.map(&:value)
    end

    def alive?(pid)
      Process.kill 0, pid
      true
    rescue Errno::ESRCH
      false
    end
end
