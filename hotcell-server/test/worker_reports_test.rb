# frozen_string_literal: true

require "test_helper"

# What a worker says about itself, and how little of it may be believed.
#
# The worker is the one process in this design that runs untrusted code, and it writes these reports over a
# socket the supervisor reads inside the loop enforcing every request's deadline. So this is the one input
# where "a compromised peer" is the case to design for rather than a hypothetical. It is exercised directly
# because the direct form reaches every malformed shape without a fixture apiece — an operation can send
# these end to end, since the control socket lives in its own process, and Fixtures::EarlyIdle does.
class WorkerReportsTest < HotCellServerTest
  def setup
    @supervisor = HotCell::Supervisor.new(directory: Dir.mktmpdir("hotcell-reports"), log: HotCell::Log.null)
    @sockets = UNIXSocket.pair(:STREAM)
    @extra_sockets = []
    @child = HotCell::Supervisor::Child.build slot: HotCell::Slot.build(Dir.mktmpdir("hotcell-slot"), 0),
                                              pid: Process.pid,
                                              control: HotCell::Connection.new(@sockets.first), deadline: 30
  end

  def teardown
    (@sockets + @extra_sockets).each { |socket| socket.close unless socket.closed? }
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

  # JSON.parse raises EncodingError rather than JSON::ParserError for a key holding bytes that are not
  # valid UTF-8, and the rescue here used to name the exceptions it expected. So one byte in one report
  # unwound `run` and took every in-flight request with it — the same denial of service as the `[]` report
  # above, from the same habit of enumerating what a parse can raise.
  def test_a_report_whose_key_is_not_valid_utf8_is_dropped
    apply %({"\xff\xfe":1,"idle":true}).b.force_encoding(Encoding::UTF_8)

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

  # The reported code rides an untrusted worker report, so it becomes a counter key and a Symbol. A report
  # of `code: []` reached `Counters#record`, which calls `to_sym`, raised NoMethodError past the rescue that
  # names only MessageError and JSON::ParserError, and `run`'s ensure shut the cell down. One malformed
  # report was a denial of service against every other request.
  def test_an_idle_report_with_a_nonstring_code_does_not_crash_the_cell
    make_busy

    apply({ idle: true, code: [] }.to_json)

    refute_predicate @child, :busy?, "the request still finishes"
    assert_equal 1, @supervisor.counters.to_h[:requests][:total]
  end

  # An unknown code becomes a permanent hash key, so a worker that reports a fresh string every time grows
  # the supervisor's memory without bound. Unknown codes collapse to one bucket instead.
  def test_unknown_idle_codes_do_not_grow_the_counters_without_bound
    3.times do |number|
      make_busy
      apply({ idle: true, code: "unique-#{number}" }.to_json)
    end

    assert_equal [ :total, :unknown ].sort, @supervisor.counters.to_h[:requests].keys.sort
  end

  # A code this cell actually mints is recorded as itself, so the sanitizing does not flatten real outcomes.
  def test_a_known_idle_code_is_recorded_as_itself
    make_busy
    apply({ idle: true, code: "failed" }.to_json)

    assert_equal 1, @supervisor.counters.to_h[:requests][:failed]
  end

  # A worker can die between the fork and the dispatch write. The rescue marked the child retired but left
  # its control socket open, so the worker stayed blocked in await_dispatch, its slot never freed, and
  # shutdown waited on it forever. Closing the control socket is what makes the worker see EOF and exit.
  def test_a_dispatch_that_fails_closes_the_control_socket_so_the_worker_exits
    @sockets.last.close

    client = UNIXSocket.pair(:STREAM)
    @extra_sockets.concat client

    result = @supervisor.send :dispatch, @child, HotCell::Connection.new(client.first), 0

    refute result, "dispatch reports the failure to the caller"
    assert @child.retired_at, "the worker is retired"
    assert_predicate @child.control.socket, :closed?, "the control socket is closed, so await_dispatch returns EOF"
    refute_predicate @child, :busy?, "the connection was handed back to be answered here"
  end

  # A listener readable in the same IO.select batch as the stop signal was still accepted after
  # `drain_signals` flipped `@stopping` and cleared the queue, so a work connection was enqueued that
  # `pump` will never dispatch, and it waited out its whole queue deadline instead of hearing `capacity`.
  def test_work_is_not_admitted_after_the_stop_signal_in_the_same_batch
    server = listener "work.sock"
    @supervisor.instance_variable_set :@work, server
    @supervisor.instance_variable_set :@stopping, true

    connect_to server
    @supervisor.send :accept_work

    assert_equal 0, @supervisor.instance_variable_get(:@queue).size
  end

  def test_control_is_not_admitted_after_the_stop_signal_in_the_same_batch
    server = listener "control.sock"
    @supervisor.instance_variable_set :@control, server
    @supervisor.instance_variable_set :@stopping, true

    connect_to server
    @supervisor.send :accept_control

    assert_equal 0, @supervisor.instance_variable_get(:@control_pending).size
  end

  # A complete report line longer than the limit was parsed and applied — the size guard only caught a
  # buffer with no newline, so a report whose newline landed in a later read bypassed the limit. Here an
  # over-limit idle report is dropped, so a busy worker stays busy rather than being finished by it.
  def test_a_worker_report_over_the_limit_is_dropped_before_it_is_applied
    @supervisor.instance_variable_get(:@children)[0] = @child
    make_busy

    @sockets.last.write JSON.generate(idle: true, code: "ok", pad: "x" * HotCell::Worker::DISPATCH_BYTES) << "\n"
    drain_reports @sockets.first

    assert_predicate @child, :busy?, "the over-limit report was dropped, not applied"
  end

  # A control message over the limit, but with its newline in a later read, reached `answer_control` and was
  # parsed and served. A metrics request padded past the limit is now refused `invalid` before the parse
  # rather than answered.
  def test_a_control_message_over_the_limit_is_refused_before_it_is_parsed
    server_side, client_side = UNIXSocket.pair(:STREAM)
    @extra_sockets.concat [ server_side, client_side ]
    pending = HotCell::Supervisor::Pending.new(HotCell::Connection.new(server_side), HotCell::Clock.now, "".b)
    @supervisor.instance_variable_get(:@control_pending) << pending

    writer = Thread.new do
      client_side.write %({"v":#{HotCell::PROTOCOL_VERSION},"op":"#{HotCell::METRICS}",) +
                        %("inputs":0,"outputs":0,"payload":{"pad":"#{"x" * 9000}"}}\n)
    rescue IOError, Errno::EPIPE
    end
    drain_control pending

    assert_failed "invalid", HotCell::Response.parse(client_side.gets)
  ensure
    writer&.kill
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

    def make_busy
      pair = UNIXSocket.pair(:STREAM)
      @extra_sockets.concat pair
      @child.dispatched HotCell::Connection.new(pair.first), 30, at: HotCell::Clock.now
    end

    def listener(name)
      path = File.join(Dir.mktmpdir("hotcell-stop"), name)
      UNIXServer.new(path).tap { |server| @extra_sockets << server }
    end

    def connect_to(server)
      client = UNIXSocket.new server.path
      @extra_sockets << client
      raise "the connection never reached the listener" unless server.wait_readable(1)

      client
    end

    def drain_reports(socket)
      @supervisor.send(:child_reported, socket) while !socket.closed? && socket.wait_readable(0.5)
    end

    def drain_control(pending)
      socket = pending.connection.socket
      while @supervisor.instance_variable_get(:@control_pending).include?(pending) && socket.wait_readable(0.5)
        @supervisor.send :read_control, pending
      end
    end
end
