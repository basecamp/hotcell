# frozen_string_literal: true

require "test_helper"

# What a worker writes to fd 2, and why it has to reach a log line at all.
#
# A C library that calls `exit()` raises nothing, so `Worker#run`'s rescue never sees it, the connection
# carries a bare `crashed`, and the only account of what happened is on fd 2. In production that stream goes
# to the container runtime's log driver, where the fleet's collector drops complete non-JSON lines — so a
# sandbox whose whole job is decoding hostile bytes had one output channel that reached nobody.
#
# Every assertion here is on the tail rather than on the whole capture, because a worker is not silent on
# every platform: off Linux, `Limits.memory_unenforceable!` warns each worker that RLIMIT_DATA cannot be
# set, and that line is on fd 2 ahead of whatever the test wrote.
class WorkerStderrTest < HotCellServerTest
  FATAL = "libgomp: Thread creation failed: Resource temporarily unavailable\n"

  def test_a_line_written_before_a_fatal_exit_arrives_on_worker_killed
    TestCell.boot(concurrency: 1) do |cell|
      failure = assert_failed "killed", write_stderr(cell, FATAL, fatal: true), cause: "crashed"

      assert_tail FATAL, killed(cell).dig(:hotcell, :stderr)
      assert_tail FATAL, failure.stderr
    end
  end

  def test_bytes_that_are_not_valid_utf8_are_scrubbed_rather_than_passed_through
    TestCell.boot(concurrency: 1) do |cell|
      assert_failed "killed", cell.call("test.garbled_stderr", timeout: 20), cause: "crashed"

      captured = killed(cell).dig(:hotcell, :stderr)

      assert_predicate captured, :valid_encoding?
      assert_tail "libgomp:  failed\n", captured
    end
  end

  # The tail rather than the head, asserted by the last line being present: a transcript's fatal is at the
  # end, and head-keeping truncation passes any assertion that only checks the length.
  def test_an_oversized_transcript_is_truncated_to_its_tail
    TestCell.boot(concurrency: 1) do |cell|
      assert_failed "killed", write_stderr(cell, FATAL, noise: 20_000, fatal: true), cause: "crashed"

      captured = killed(cell).dig(:hotcell, :stderr)

      assert_tail FATAL, captured
      assert_operator captured.bytesize, :<=, HotCell::Failure::MAX_MESSAGE_BYTES
    end
  end

  # No field at all rather than a null. `Log#document` does not compact the hotcell namespace, so a nil here
  # would put `"stderr":null` on every death a cell reports. Asserted on the buffer rather than through a
  # cell because this has to hold on every platform, and off Linux no worker is silent.
  def test_a_child_that_captured_nothing_contributes_no_field
    assert_empty build_child(stderr: nil).stderr_field
  end

  def test_a_worker_that_writes_nothing_produces_no_field
    skip "a worker warns that RLIMIT_DATA is not settable off Linux" unless RUBY_PLATFORM.include?("linux")

    TestCell.boot(concurrency: 1, deadline: 0.3) do |cell|
      assert_failed "killed", cell.call("test.uninterruptible", timeout: 20), cause: "deadline"

      refute killed(cell).fetch(:hotcell).key?(:stderr),
             "expected no stderr field for a worker that said nothing"
    end
  end

  # A warning is not a death, and the field exists to make a death legible rather than to ship a cell's
  # stderr anywhere. So a worker that warns and then answers normally reports nothing, and its `worker.reaped`
  # carries no capture — which is also what keeps a chatty library off every reap in the fleet.
  def test_a_worker_that_warns_and_then_succeeds_reports_nothing
    TestCell.boot(concurrency: 1) do |cell|
      assert_ok write_stderr(cell, "vips warning: ignoring ICC profile\n")

      wait_until(what: "the worker to be reaped") { cell.log_events("worker.reaped").any? }

      refute cell.log_events("worker.reaped").first.fetch(:hotcell).key?(:stderr)
      assert_empty cell.log_events("worker.killed")
    end
  end

  # The clear at dispatch, from the direction that matters: a warning the worker survived must not be
  # attached to a later request's death. Needs a reused worker, which the default configuration never
  # produces.
  def test_a_warning_from_an_earlier_request_does_not_reach_a_later_requests_death
    TestCell.boot(concurrency: 1, max_requests_per_worker: 2) do |cell|
      assert_ok write_stderr(cell, "vips warning: ignoring ICC profile\n")
      assert_failed "killed", write_stderr(cell, "", fatal: true), cause: "crashed"

      refute_includes killed(cell).dig(:hotcell, :stderr).to_s, "vips warning",
                      "the earlier request's warning was attached to this one's death"
    end
  end

  # A leaked pipe end per fork is a descriptor the supervisor never gets back, and it surfaces as EMFILE
  # under churn rather than anywhere near the code that caused it. Counted in the supervisor's own process,
  # which is why this needs procfs.
  #
  # A ceiling rather than an equality, and the baseline is taken before the first request: a leak only ever
  # pushes the count up, while an unreferenced IO the supervisor has finished with is closed whenever its
  # process next collects, so the count legitimately falls. Asserting equality against a post-request
  # baseline failed on Ruby 4.0 with two descriptors fewer than it started with.
  def test_worker_churn_leaves_no_descriptors_behind_in_the_supervisor
    TestCell.boot(concurrency: 1) do |cell|
      pid = cell.log_events("cell.boot").first.dig(:process, :pid)
      booted = supervisor_descriptors(pid)

      5.times { assert_ok cell.call("test.echo") }
      wait_until(what: "every worker to be reaped") { cell.log_events("worker.reaped").size == 5 }

      assert_operator supervisor_descriptors(pid), :<=, booted,
                      "the supervisor kept descriptors from the workers it forked"
    end
  end

  # Pins the decision `Supervisor#become_worker` records, rather than the plumbing. That code sets the flag
  # explicitly and `IO.pipe` would supply it anyway, so this asserts the property the two of them exist to
  # guarantee: whatever a later edit does to either, a conversion must never wait on the supervisor.
  def test_a_workers_fd_2_is_non_blocking
    TestCell.boot(concurrency: 1) do |cell|
      assert_equal({ nonblock: true }, assert_ok(cell.call("test.stderr_flags")).result)
    end
  end

  # Bounded, because "until end of stream" never arrives while a descendant holds the write end, and
  # "until the pipe is momentarily empty" terminates only by winning a race against whoever is writing.
  # Driven against a temp file: how much a pipe or a socketpair buffers is platform-dependent, and this
  # suite runs on macOS too.
  def test_the_final_drain_after_exit_stops_at_its_bound
    budget = HotCell::Supervisor::STDERR_READ_BYTES * HotCell::Supervisor::STDERR_FINAL_READS

    with_file do |path|
      File.binwrite path, "x" * (budget * 2)

      File.open(path, "rb") do |source|
        child = build_child stderr: source
        supervisor.send :drain_stderr_after_exit, child

        assert_equal budget, source.pos, "expected the drain to stop at its bound"
        assert_operator File.size(path), :>, source.pos
      end
    end
  end

  # The sweep-then-drain path with something still writing. It does **not** catch an unbounded drain: the
  # supervisor wins that race in practice, which is why the bound is asserted directly above.
  def test_a_descendant_still_writing_at_reap_does_not_stop_the_cell_answering
    TestCell.boot(concurrency: 1) do |cell|
      assert_failed "killed", cell.call("test.stderr_descendant", timeout: 20), cause: "crashed"

      assert_includes killed(cell).dig(:hotcell, :stderr).to_s, "from the descendant"
    end
  end

  private
    def supervisor_descriptors(pid)
      skip "counting another process's descriptors needs procfs" unless File.directory?("/proc/#{pid}/fd")

      Dir.children("/proc/#{pid}/fd").size
    end

    def assert_tail(expected, captured)
      assert captured&.end_with?(expected), "expected a capture ending in #{expected.inspect} " \
                                            "and got #{captured.inspect}"
    end

    def write_stderr(cell, text, noise: 0, fatal: false)
      cell.call "test.stderr_writer", payload: { text: text, noise: noise, fatal: fatal }, timeout: 20
    end

    def killed(cell)
      wait_for_event(cell, "worker.killed").first or flunk "the cell never wrote worker.killed"
    end

    def supervisor
      HotCell::Supervisor.new directory: Dir.mktmpdir("hotcell-stderr"), log: HotCell::Log.null
    end

    def build_child(stderr:)
      HotCell::Supervisor::Child.build slot: HotCell::Slot.build(Dir.mktmpdir("hotcell-slot"), 0),
                                       pid: Process.pid, control: HotCell::Connection.new(UNIXSocket.pair.first),
                                       deadline: 30, stderr: stderr
    end
end
