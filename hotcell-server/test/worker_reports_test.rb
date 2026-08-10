# frozen_string_literal: true

require "test_helper"

# What a worker says about itself, and how little of it may be believed.
#
# The worker is the one process in this design that runs untrusted code, and it writes these reports over a
# socket the supervisor reads inside the loop enforcing every request's deadline. So this is the one input
# where "a compromised peer" is the case to design for rather than a hypothetical, and it is exercised
# directly: an operation cannot reach its worker's control socket, so nothing end to end can send these.
class WorkerReportsTest < HotCellServerTest
  def setup
    @supervisor = HotCell::Supervisor.new(directory: Dir.mktmpdir("hotcell-reports"), log: HotCell::Log.null)
    @sockets = UNIXSocket.pair(:STREAM)
    @child = HotCell::Supervisor::Child.build slot: HotCell::Slot.build(Dir.mktmpdir("hotcell-slot"), 0),
                                              pid: Process.pid,
                                              control: HotCell::Connection.new(@sockets.first), deadline: 30
  end

  def teardown
    @sockets.each { |socket| socket.close unless socket.closed? }
  end

  # The cell's own maximum, which is what a reported deadline is clamped against.
  CEILING = HotCell::Configuration::LIMITS[:deadline]

  # `Payload.parse` answers with whatever the JSON held, so a report that is not an object reached
  # `message[:deadline]` as `Array#[]` and raised TypeError. Nothing above `run` rescues that, and its
  # `ensure` shuts the cell down — a one-line denial of service from a worker against every other request.
  def test_a_report_that_is_not_an_object_is_dropped_rather_than_taking_the_cell_down
    apply "[]"
    apply "\"idle\""
    apply "12"

    assert_equal 30, @child.deadline
  end

  def test_a_report_that_is_not_json_is_dropped
    apply "{not json"

    assert_equal 30, @child.deadline
  end

  # An idle report from a worker holding nothing used to clear `dispatched_at`, which is what `overdue?`
  # reads — so a worker could answer "I am done" and buy itself an unbounded deadline on a request it was
  # still working on.
  def test_an_idle_report_from_a_worker_with_no_request_is_refused
    refute_predicate @child, :busy?

    apply({ idle: true, code: "ok" }.to_json)

    assert_nil @child.connection
  end

  def test_an_idle_report_from_a_busy_worker_is_believed
    @child.dispatched HotCell::Connection.new(UNIXSocket.pair(:STREAM).first), 30, at: HotCell::Clock.now

    apply({ idle: true, code: "ok" }.to_json)

    refute_predicate @child, :busy?
  end

  # A deadline may only ever narrow. It arrives from the untrusted side, so anything that is not a positive
  # number leaves the cell's own maximum standing.
  def test_a_reported_deadline_may_only_narrow
    apply({ deadline: 5 }.to_json)
    assert_equal 5, @child.deadline

    apply({ deadline: 9_000 }.to_json)
    assert_equal CEILING, @child.deadline

    apply({ deadline: "soon" }.to_json)
    assert_equal CEILING, @child.deadline
  end

  # `running < concurrency ||` short-circuited the cap. That reads like a fast path and is a hole: when fork
  # fails with EAGAIN nothing runs, `running` stays 0, the left side is always true, and the queue grows
  # without bound — under exactly the host pressure the fork rescue exists to survive.
  def test_the_queue_is_capped_even_when_nothing_can_be_forked
    supervisor = HotCell::Supervisor.new(directory: Dir.mktmpdir("hotcell-admission"), log: HotCell::Log.null,
                                         configuration: HotCell::Configuration.new(concurrency: 2, queue_size: 2))
    queue = supervisor.instance_variable_get(:@queue)

    20.times { supervisor.send :admit?, queue.size }

    assert_equal 0, queue.size, "nothing was enqueued by the probe itself"
    assert supervisor.send(:admit?, 0), "an idle cell accepts"
    refute supervisor.send(:admit?, 4), "concurrency 2 + queue_size 2 is the whole cell"
    refute supervisor.send(:admit?, 99)
  end

  private
    def apply(line)
      @supervisor.send :apply_report, @child, "#{line}\n"
    end
end
