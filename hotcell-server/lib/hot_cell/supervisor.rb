# frozen_string_literal: true

require "socket"
require "fileutils"
require "tmpdir"

module HotCell
  # Accepts, queues, dispatches, times, kills, reaps, and cleans up. It never evaluates image data.
  #
  # That last rule is mechanical rather than defensive: libvips starts its thread pool on the first
  # evaluation and that pool does not survive fork, so a supervisor that has touched an image forks
  # workers that deadlock forever. Reading a request line would be harmless — it is a control message from
  # the trusted side on a bounded buffer — but the supervisor does not need to, and staying out of the
  # request is what lets it dispatch a connection whose descriptors are still queued on it.
  #
  # Dispatching rather than letting workers accept is what makes the rest work. The supervisor needs to own
  # the accept anyway, for the queue, for queued_ms, and to answer `capacity`. It also means the supervisor
  # knows when every worker started its current request, which is what the deadline needs.
  class Supervisor
    # Owns "is this worker busy" and the two transitions that change the answer, because the supervisor asking
    # `busy?` and the supervisor assigning the four fields `busy?` is computed from are the same fact. Spread
    # across the caller, a new field is one the next transition forgets to clear.
    Child = Struct.new(:slot, :pid, :control, :connection, :dispatched_at, :deadline, :served, :killed_for,
                       :retired_at, :buffer, keyword_init: true) do
      def self.build(slot:, pid:, control:, deadline:)
        new slot: slot, pid: pid, control: control, deadline: deadline, served: 0, buffer: "".b
      end

      def dispatched(connection, deadline, at:)
        self.connection = connection
        self.dispatched_at = at
        self.deadline = deadline
        self.killed_for = nil
        self.served += 1
      end

      # Not a reset of `deadline`: the supervisor re-establishes it on the next dispatch, and leaving the last
      # one readable is what lets a log line after the fact say what this worker was being held to.
      def finished
        connection&.close
        released
      end

      # Stop being busy while leaving the connection open, for the one caller that still has to answer on it.
      def released
        self.connection = nil
        self.dispatched_at = nil
      end

      def busy?
        !connection.nil?
      end

      def available?
        !busy? && retired_at.nil?
      end

      # A child already killed for its deadline stops being a timer, and that guard is load-bearing rather
      # than tidy. Killing does not clear `busy?` — the supervisor still holds the connection it has to answer
      # on — so without it `expires_at` stays in the past, `wait_for` returns 0, IO.select returns at once,
      # and the loop re-kills and re-logs on every pass until the reap. Measured at a 0.2s deadline: 72
      # SIGKILLs and 72 synchronous stdout writes for one breach. The window is longest exactly when the host
      # is already struggling — a worker in uninterruptible sleep, or one tearing down gigabytes of mappings —
      # and the loop it starves is the one enforcing every other request's deadline.
      def overdue?(now)
        busy? && killed_for.nil? && now - dispatched_at >= deadline
      end

      def expires_at
        dispatched_at + deadline if busy? && killed_for.nil?
      end

      # The retirement analogue of `overdue?`, and the only timer that can reach a worker whose idle
      # report was early: `finish` clears what `overdue?` reads, so a worker still running what it
      # reported finished answers to this and nothing else. A retired worker has nothing left to do but
      # exit — its closed control socket ends its await_dispatch — so the wait for it is bounded where an
      # available worker's is not. Busy is excluded because a busy retired child is a worker that already
      # died mid-request, which the reap answers for. `killed_for` is the same one-kill latch `overdue?`
      # reads.
      def lingering?(now, grace)
        !busy? && killed_for.nil? && !retired_at.nil? && now - retired_at >= grace
      end

      def lingers_until(grace)
        retired_at + grace if !busy? && killed_for.nil? && !retired_at.nil?
      end
    end

    # A path longer than this fails to bind with an error that does not say so. Darwin allows four fewer
    # bytes than Linux, and control.sock is the longer of the two names, so it overflows first.
    SUN_PATH_MAX = RUBY_PLATFORM.include?("darwin") ? 104 : 108

    # The signals this cell can attribute to the request the worker was holding. XFSZ is that worker passing
    # RLIMIT_FSIZE, and SEGV, ABRT and TRAP are how libvips and GLib die on their own allocation failures —
    # libvips dereferences null after printing the correct diagnostic, and g_malloc aborts.
    #
    # These three are the worker hitting its own per-worker RLIMIT_DATA, which is a property of the input
    # this worker held, so the same bytes do it again and the verdict is permanent. `Codes` says a signal
    # tells how a process died and never why, so a signal is transient by default — and that is not in
    # conflict with a permanent verdict here, because aggregate pressure the worker did not cause arrives as
    # SIGKILL, not as these. The two are different signals, and SIGKILL is excluded below.
    #
    # SIGKILL is deliberately absent, and its absence is the point. The supervisor's own deadline kill is
    # already named by `killed_for`, so a SIGKILL reaching this table came from somewhere this process
    # cannot see: a cgroup OOM chosen on aggregate pressure, or a sibling worker, which shares a uid and is
    # not prevented from signalling. Reading it as this request's memory condemned an input for someone
    # else's pressure.
    #
    # Anything not here is `crashed`, which is also where a worker that exited without a signal lands. They
    # were two names, `signal` and `crashed`, for one amount of knowledge: the worker died and nothing says
    # why. One name is honest about that.
    SIGNAL_CAUSES = {
      "XFSZ" => Codes::FSIZE,
      "SEGV" => Codes::MEMORY,
      "ABRT" => Codes::MEMORY,
      "TRAP" => Codes::MEMORY,
    }.freeze

    SOCKETS = [ "work.sock", "control.sock" ].freeze

    # Request memory is protected by kernel.yama.ptrace_scope >= 1, and nothing else protects it. That is a
    # host sysctl no container flag can supply.
    PTRACE_SCOPE = "/proc/sys/kernel/yama/ptrace_scope"

    # A control connection that has not sent its request yet. Reading it non-blockingly is what stops a
    # client that connects and then says nothing from stalling the loop every conversion depends on.
    Pending = Struct.new(:connection, :accepted_at, :buffer)

    # Only to bound the list. The channel's whole value is answering when nothing else does, so this is set
    # far above any real scrape rate rather than as a throttle.
    CONTROL_BACKLOG = 64

    attr_reader :configuration, :counters, :log, :directory, :workspace

    def initialize(directory:, workspace: nil, configuration: HotCell.configuration, log: Log.new,
                   ptrace_scope_path: PTRACE_SCOPE)
      @directory = directory
      @workspace = workspace || File.join(Dir.tmpdir, "hotcell-workspace")
      @configuration = configuration
      @log = log
      @ptrace_scope_path = ptrace_scope_path
      @children = {}
      @queue = []
      @control_pending = []
      @counters = Counters.new
      @stopping = false
    end

    def boot
      verify_socket_paths!
      verify_limits!
      verify_ptrace_scope!
      prepare_directories
      preload
      @work = listen "work.sock"
      @control = listen "control.sock"
      @control_handler = Control.new(configuration: configuration, counters: counters)
      trap_signals

      log.write "cell.boot", pid: Process.pid, directory: directory, operations: Registry.names,
                             configuration: configuration.to_h
      self
    end

    def run
      until stopped?
        readable, = IO.select(sources, nil, nil, wait_for)
        Array(readable).each { |source| handle source }

        enforce_deadlines
        enforce_retirements
        expire_queue
        expire_control
        retire_idle if @stopping
        pump
      end
    ensure
      shutdown
    end

    private
      # SIGTERM is the only way in. drain_signals owns the transition because the log line and the queue
      # refusal are what it means; a setter that skipped them would be a trap rather than an affordance.
      def stopped?
        @stopping && @children.empty?
      end

      def sources
        [ @signals ].tap do |list|
          list.concat @children.each_value.map { |child| child.control.socket }.reject(&:closed?)
          list.concat @control_pending.map { |pending| pending.connection.socket }.reject(&:closed?)
          list.push @work, @control unless @stopping
        end
      end

      # The nearest thing that needs doing without anybody knocking: a deadline, a queued connection that
      # has waited long enough to be told so, or a control client that never said what it wanted.
      def wait_for
        now = Clock.now
        nearest = [ *@children.each_value.filter_map(&:expires_at),
                    *@children.each_value.filter_map { |child| child.lingers_until(Configuration::KILL_GRACE) },
                    *@queue.map { |(_, queued_at)| queued_at + configuration.queue_wait },
                    *@control_pending.map { |pending| pending.accepted_at + configuration.control_deadline } ].min
        return nil if nearest.nil?

        [ nearest - now, 0 ].max
      end

      def handle(source)
        case source
        when @signals then drain_signals
        when @work then accept_work
        when @control then accept_control
        else
          pending = pending_control(source)
          pending ? read_control(pending) : child_reported(source)
        end
      end

      # Reap on SIGCHLD, not at the top of the accept loop. A worker killed by a resource limit cannot
      # report its own death, so the supervisor reports it — and a supervisor that only reaps when the next
      # connection arrives never reports it on an idle cell, leaving the caller to wait out its whole
      # timeout for a worker that died in the first second.
      #
      # **Accepted risk.** Handling TERM is also how a worker stops the whole cell. Workers share this
      # process's uid, so they may signal it; the kernel protects a namespace's pid 1 from signals it has no
      # handler for, and this installs one. A worker can SIGKILL its siblings for the same reason, which
      # `Codes` already relies on when it refuses to attribute a signal to the input a worker was holding.
      # The premise is that handling TERM is not optional — it is how an orchestrator stops a cell without
      # killing requests in flight — and that denial of service against a cell is out of scope per
      # docs/DESIGN.md.
      def trap_signals
        @signals, @signal_writer = IO.pipe
        trap("CHLD") { @signal_writer.write_nonblock "C", exception: false }
        [ "INT", "TERM" ].each do |signal|
          trap(signal) { @signal_writer.write_nonblock "S", exception: false }
        end
      end

      def drain_signals
        bytes = @signals.read_nonblock(256, exception: false)
        return if bytes.nil? || bytes == :wait_readable

        if bytes.include?("S") && !@stopping
          @stopping = true
          log.write "cell.stopping", pid: Process.pid, running: running, queued: @queue.size
          refuse_queue "the cell is stopping"
        end

        reap
      end

      # `sources` drops the listeners once `@stopping` is set, but a listener already readable in the same
      # IO.select batch as the stop signal is still handled this pass. Refusing here rather than admitting a
      # connection the stopping cell will never pump is what closes that one-batch window. The connection is
      # left in the backlog and reset when the listener closes at shutdown, which the caller reads as transient.
      def accept_work
        return if @stopping

        socket = @work.accept_nonblock(exception: false)
        return if socket == :wait_readable

        connection = Connection.new(socket)

        if admit?(@queue.size)
          @queue << [ connection, Clock.now ]
          counters.observe_queue @queue.size
        else
          refuse connection, "the queue is full at #{@queue.size}"
        end
      end

      def accept_control
        return if @stopping

        socket = @control.accept_nonblock(exception: false)
        return if socket == :wait_readable

        connection = Connection.new(socket)

        if @control_pending.size >= CONTROL_BACKLOG
          answer connection, Failure.new(code: "capacity", message: "#{CONTROL_BACKLOG} control connections are already waiting")
        else
          @control_pending << Pending.new(connection, Clock.now, "".b)
        end
      end

      # Everything accepted and not yet answered, against everything this cell can hold. `running <
      # concurrency ||` used to short-circuit this, which sounds like a fast path and is a hole: when fork
      # fails with EAGAIN nothing runs, `running` stays 0, the left side is always true, and the queue grows
      # without bound — under exactly the host pressure the fork rescue exists to survive, until this process
      # runs out of descriptors in an accept nobody rescues.
      def admit?(queued)
        running + queued < configuration.concurrency + configuration.queue_size
      end

      def pending_control(socket)
        @control_pending.find { |pending| pending.connection.socket == socket }
      end

      # Keep whatever arrived and come back for the rest. A stream socket does not promise the whole line
      # lands in one read, and a blocking read here would put the loop at the mercy of a control client.
      def read_control(pending)
        chunk = pending.connection.socket.read_nonblock(MAX_REQUEST_BYTES, exception: false)
        return if chunk == :wait_readable

        return drop_control(pending) if chunk.nil?

        pending.buffer << chunk

        # Size before newline, so a complete line over the limit is refused rather than parsed. Checking the
        # newline first handed an oversized-but-terminated message to the parser whenever its newline arrived
        # in a later read, which is the limit the read is here to enforce.
        if pending.buffer.bytesize > MAX_REQUEST_BYTES
          @control_pending.delete pending
          answer pending.connection,
                 Failure.new(code: "invalid", message: "control message over #{MAX_REQUEST_BYTES} bytes")
        elsif pending.buffer.include?("\n")
          @control_pending.delete pending
          answer_control pending.connection, pending.buffer.force_encoding(Encoding::UTF_8)
        end
      end

      # A control answer that cannot be serialized must not take the cell down with it. This channel exists to
      # be available when nothing else is, and it runs inside the loop every conversion depends on — so
      # anything raised while answering a scrape would stop the cell serving.
      #
      # **No test, because nothing can currently raise here.** `max_requests_per_worker: :unlimited` used to: a
      # Symbol is not JSON-native, so a cell configured that way could not describe itself. Configuration#to_h
      # reports it as a String now, and nothing else describe or metrics returns is unserializable. The rescue stays
      # for the next field added to either — one unserializable value would otherwise stop the cell serving
      # conversions, and this channel exists to answer when nothing else does.
      def answer_control(connection, line)
        response = begin
          @control_handler.answer(line, running: running, queued: @queue.size).to_line
        rescue StandardError => error
          log.write "control.unanswerable", error: error.class.name, message: Failure.sanitize(error.message)
          Response.failed(Failure.new(code: "failed", error_class: error.class.name,
                                      message: error.message)).to_line
        end

        connection.write_line response
      rescue SystemCallError, IOError
        counters.cancelled!
      ensure
        connection.close
      end

      def expire_control
        return if @control_pending.empty?

        now = Clock.now
        @control_pending.reject! do |pending|
          next false if now - pending.accepted_at < configuration.control_deadline

          log.write "control.abandoned", waited_s: configuration.control_deadline
          pending.connection.close
          true
        end
      end

      def drop_control(pending)
        @control_pending.delete pending
        pending.connection.close
      end

      def pump
        return if @stopping

        while @queue.any? && (child = available_child)
          connection, queued_at = @queue.shift
          break unless dispatch child, connection, Clock.ms_since(queued_at)
        end
      end

      # A worker can die between the fork and this write. Answering rather than raising is what keeps one dead
      # worker from taking the whole cell down with it, and the caller gets a transient verdict either way.
      def dispatch(child, connection, queued_ms)
        child.dispatched connection, configuration.limits.deadline, at: Clock.now

        child.control.send_message JSON.generate({ queued_ms: queued_ms }) << "\n",
                                   descriptors: [ connection ]
        true
      rescue SystemCallError, IOError => error
        log.write "worker.undispatchable", pid: child.pid, slot: child.slot.number,
                                           error: error.class.name

        # Released rather than finished: this is the only path that hands the connection back to be answered
        # here, so the client connection must not be closed on the way out. `retire` closes the worker's
        # control socket, which is a different socket — without it the worker stays blocked in await_dispatch,
        # never frees its slot, and shutdown waits on it forever.
        child.released
        retire child
        answer connection, Failure.new(code: Codes::KILLED, cause: Codes::CRASHED, message: error.message)
        false
      end

      def available_child
        @children.each_value.find(&:available?) || spawn
      end

      def spawn
        number = free_slot or return nil
        slot = Slot.build(workspace, number)
        supervisor_side, worker_side = UNIXSocket.pair(:STREAM)

        # A fork that fails is a host under pressure, not a reason to stop serving. The request stays queued
        # and is either dispatched on a later pass or answered `capacity` when its wait runs out.
        pid = begin
          fork do
            become_worker supervisor_side
            Worker.new(slot: slot, configuration: configuration, control: Connection.new(worker_side),
                       log: log).run
          end
        rescue SystemCallError => error
          log.write "worker.unforkable", slot: number, error: error.class.name, message: error.message
          supervisor_side.close
          worker_side.close
          return nil
        end

        worker_side.close
        log.write "worker.forked", pid: pid, slot: number

        @children[number] = Child.build(slot: slot, pid: pid, control: Connection.new(supervisor_side),
                                        deadline: configuration.limits.deadline)
      end

      # Everything the supervisor holds and the worker must not: the listener, the signal pipe, the other
      # children's control sockets, and every connection the supervisor is still holding for somebody else.
      # The connection this worker is about to serve arrives over SCM_RIGHTS a moment from now, so closing
      # the inherited copy here costs nothing and stops it lingering for the worker's whole life.
      def become_worker(supervisor_side)
        [ "CHLD", "INT", "TERM" ].each { |signal| trap signal, "DEFAULT" }

        # Its own process group, so the deadline reaches the tools this request started rather than only the
        # Ruby process that started them. A tool is a grandchild — the worker spawns it — and killing the
        # worker alone left it running, reparented to this supervisor as pid 1, with no deadline, no slot
        # and nothing watching it. A document that hangs ffmpeg would have accumulated one orphan per
        # request until the cgroup ended the cell.
        #
        # **Accepted risk.** A process group is voluntary, so it holds for a tool that behaves and not for
        # one that does not. Code running in a worker's child can call `setsid` and leave, which needs no
        # capability and so survives `cap-drop ALL`, and neither the deadline kill nor the reap sweep reaches
        # it afterwards. It then runs untimed until `pids-limit` or the cgroup ends it.
        #
        # It reaches further than that, so this is not the denial of service docs/DESIGN.md puts out of
        # scope. A stolen listener needs a live process to hold it, and this escape is the only way one
        # outlives the reap — so it is what turns the socket theft under "Worker isolation" from a dead
        # socket path into a cell that intercepts every later request.
        #
        # The premise is that nothing in this process prevents it. A process group is the only bound the
        # supervisor can impose, and every stronger one needs a capability `cap-drop ALL` removes, for the
        # reasons that section records. Landlock is the candidate that fits, tracked at basecamp/hotcell#13.
        Process.setpgid 0, 0

        supervisor_side.close
        @signals.close
        @signal_writer.close
        @work.close
        @control.close

        @children.each_value do |child|
          child.control.close
          child.connection&.close
        end
        @queue.each { |(connection, _)| connection.close }
        @control_pending.each { |pending| pending.connection.close }
      end

      # Buffered and non-blocking, for the same reason read_control is, and more so: readability means a byte
      # arrived rather than a line, and the peer here is the one process in this design that runs untrusted
      # code. A blocking read would let a worker that writes half a report and then stops park the very loop
      # that enforces its deadline. Draining every complete line rather than the first also means a read that
      # carries two reports cannot strand the second in this process's own IO buffer, where the kernel buffer
      # is empty and select will never fire again.
      #
      # **No test, because neither hazard can be triggered as the code stands.** A report is one small write,
      # well under PIPE_BUF, so a worker cannot write half of one; and 160 requests across four concurrent
      # callers at max_requests_per_worker 8 never coalesced two reports into a single read. Both defences are here
      # for the change that makes them reachable — a longer report, or a worker that writes in more than one call —
      # after which a blocking read parks the loop enforcing every deadline, and a stranded second report leaves the
      # supervisor waiting on a worker that already answered. Both kill the cell, and both cost about four lines to
      # prevent.
      def child_reported(socket)
        child = @children.each_value.find { |candidate| candidate.control.socket == socket }
        return if child.nil?

        # `exception: false` maps a would-block and end of stream to values, and nothing else: a worker
        # that exits with a dispatch still queued unread on this socket resets it, and the read raised
        # Errno::ECONNRESET — which nothing above here rescued, so one dead worker unwound the run loop and
        # ended the cell with every in-flight request. Any errno on this socket says what end of stream
        # says: the worker is gone.
        chunk = begin
          socket.read_nonblock(Worker::DISPATCH_BYTES, exception: false)
        rescue SystemCallError
          nil
        end
        return if chunk == :wait_readable

        # End of stream means the worker is gone. Retire it as well as closing, or it stays eligible for the
        # next dispatch until the reap catches up.
        return retire(child) if chunk.nil?

        child.buffer << chunk

        # A complete line over the limit is dropped rather than parsed. The trailing size check catches a
        # buffer that never terminates; a line whose newline arrived in a later read is complete, so its size
        # is checked here or the limit is one the parser never sees.
        while (newline = child.buffer.index("\n"))
          line = child.buffer.slice!(0, newline + 1).force_encoding(Encoding::UTF_8)

          if line.bytesize > Worker::DISPATCH_BYTES
            unreadable_report child, "report is #{line.bytesize} bytes, over the #{Worker::DISPATCH_BYTES} byte limit"
          else
            apply_report child, line
          end
        end

        return if child.buffer.bytesize <= Worker::DISPATCH_BYTES

        log.write "worker.unreadable_report", pid: child.pid,
                                              message: "report passed #{Worker::DISPATCH_BYTES} bytes with no newline"
        child.buffer.clear
      end

      # The peer here is the one process in this design that runs untrusted code, so nothing it writes may be
      # taken on trust — including its shape. `Payload.parse` answers with whatever the JSON held, and a
      # worker writing `[]` used to reach `message[:deadline]` as `Array#[]`, raise TypeError, and take the
      # cell down, because nothing above `run` catches anything. A compromised worker had a one-line denial
      # of service against every other request.
      #
      # The rescue below names only MessageError, and it can, because Payload.parse now answers with that
      # however the JSON layer failed. Naming the exceptions here is what let the TypeError through, and
      # then an EncodingError from a key holding bytes that are not valid UTF-8.
      #
      # `idle` is only believed from a worker that is actually serving something. A premature one used to
      # clear `dispatched_at`, which is what `overdue?` reads — so a worker could answer "I am done" and buy
      # itself an unbounded deadline on a request it was still holding. One from a busy worker is still
      # believed, because no check here can see the difference — what it buys is bounded instead: the next
      # dispatch restores a deadline, and retirement, where every worker ends, is enforced.
      #
      # **Accepted risk.** "Where every worker ends" is not true at `max_requests_per_worker: :unlimited`.
      # `retire?` is false for every count there, so a worker that lies about being idle is neither busy nor
      # retired, `wait_for` holds no timer for it, and the deadline is the only thing that could have killed
      # it. A compromised worker at that setting is therefore unkillable by this cell until the container is
      # replaced. The premise is that `:unlimited` already concedes the larger half of this: the worker holds
      # every one of its requests in one address space, so an input that runs code reaches all of them, which
      # is what adr/0001 and the deployment guide's trade-off section already say. A worker lifetime cap
      # would close it and is a new setting, not a fix to this one.
      def apply_report(child, line)
        message = Payload.parse(line)
        return unreadable_report child, "report is a #{message.class} and must be an object" unless message.is_a?(Hash)

        if message[:deadline]
          child.deadline = narrowed_deadline(message[:deadline])
        elsif message[:idle]
          return unreadable_report child, "idle report from a worker with no request" unless child.busy?

          finish child, message[:code]
        end
      rescue MessageError => error
        unreadable_report child, Failure.sanitize(error.message)
      end

      # The rename that takes a finished request's directory out of the way, and a line when it does not
      # happen. A failure is tolerated by design — the tree is left where it is, for a later worker to sweep
      # off the hot path, because the supervisor must never delete one inline. It is not tolerated silently:
      # the random suffix exists because a tool running as this user can pre-create a colliding name, so a
      # rename that fails is the shape of that attempt as well as of an ordinary error.
      def discard(child)
        home = child.slot.home
        return if child.slot.discard_home

        log.write "slot.undiscarded", pid: child.pid, slot: child.slot.number, home: home
      end

      def unreadable_report(child, message)
        log.write "worker.unreadable_report", pid: child.pid, message: message
        nil
      end

      def finish(child, code)
        counters.record outcome_code(code)
        child.finished
        discard child

        retire child if configuration.retire?(child.served)
      end

      # The outcome code rides an untrusted worker report and becomes both a counter key and a Symbol, so it
      # is bounded to a code this cell mints before either happens. Without this a report of `code: []` raised
      # NoMethodError on `to_sym` past `apply_report`'s rescue and took the cell down, and a stream of unique
      # strings grew the counters without bound. An unknown code is recorded, so a misreporting worker is
      # visible rather than silent, but under one fixed bucket.
      def outcome_code(reported)
        return reported if reported.is_a?(String) && (reported == "ok" || Codes.known?(reported))

        "unknown"
      end

      # Closing the control socket is the retirement: the worker's next await_dispatch sees end of stream
      # and exits. The slot stays taken until the process is actually gone — and `retired_at` is what
      # bounds that wait, in enforce_retirements. It only ever moves forward from nil, so retiring an
      # already-retired child does not buy it a fresh grace.
      def retire(child)
        child.retired_at ||= Clock.now
        child.control.close
      end

      def retire_idle
        @children.each_value.select(&:available?).each { |child| retire child }
      end

      def enforce_deadlines
        now = Clock.now

        @children.each_value.select { |child| child.overdue?(now) }.each do |child|
          child.killed_for = Codes::DEADLINE

          # Kill first, log second. Log#write is synchronous on purpose, so a container log pipe nobody is
          # draining blocks it — and with the write first, a stalled pipe meant the overdue worker was never
          # killed and no other request's deadline was enforced either.
          kill_group child

          log.write "worker.deadline", pid: child.pid, slot: child.slot.number, deadline_s: child.deadline
        end
      end

      # The deadline cannot reach a worker that is not busy, so a retired worker that never exited was
      # timed by nothing: it held its slot until it left on its own, and it held `stopped?` false forever —
      # a stopping cell waited on it until the runtime force-killed the container. KILL_GRACE is the
      # budget, because a retired worker's next act is exiting, and one still here after that is not going
      # to leave on its own.
      def enforce_retirements
        now = Clock.now

        @children.each_value.select { |child| child.lingering?(now, Configuration::KILL_GRACE) }.each do |child|
          # The latch rather than a verdict: a lingering child is never busy, so no caller hears this cause.
          child.killed_for = Codes::CRASHED

          kill_group child

          log.write "worker.lingered", pid: child.pid, slot: child.slot.number, grace_s: Configuration::KILL_GRACE
        end
      end

      # Sweeps whatever the reaped worker left in its process group — a tool it spawned outlives it on any
      # death that was not the deadline kill, a crash or a SIGKILL from outside, and would then run with no
      # deadline until the cgroup ended the cell. The deadline path already swept a live worker's group; this
      # covers every other death.
      #
      # Only the group kill applies here, never `kill_group`'s fallback to the bare pid: the leader was
      # reaped a few lines up, so the bare pid is either gone or, after enough churn, another process — and
      # the sweep must not signal it. An empty group is the common case, so ESRCH is expected. It is safe to
      # kill the group by the leader's pid even though the leader is reaped, because the supervisor is single
      # threaded and mints group leaders only in `spawn`, which cannot run between the `wait2` above and here.
      def sweep_group(child)
        Process.kill :KILL, -child.pid
      rescue Errno::ESRCH
        nil
      end

      # The whole process group, which is the worker and everything it started. Negative pid is the group.
      # Falls back to the worker alone if the group is already gone, so a worker that died between the check
      # and the signal is not an error.
      def kill_group(child)
        Process.kill :KILL, -child.pid
      rescue Errno::ESRCH
        begin
          Process.kill :KILL, child.pid
        rescue Errno::ESRCH
          nil
        end
      end

      def expire_queue
        return if @queue.empty?

        now = Clock.now
        @queue.reject! do |(connection, queued_at)|
          next false if now - queued_at < configuration.queue_wait

          refuse connection, "waited #{(now - queued_at).round(1)}s in the queue"
          true
        end
      end

      def refuse_queue(reason)
        @queue.each { |(connection, _)| refuse connection, reason }
        @queue.clear
      end

      # No recvmsg, deliberately. The caller's descriptors are still queued on this connection and the
      # kernel discards them when it closes, so a refusal never installs a descriptor in this process.
      def refuse(connection, reason)
        counters.record "capacity"
        answer connection, Failure.new(code: "capacity", message: reason), timing: { queued_ms: 0 }
      end

      def reap
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break if pid.nil?

          child = @children.each_value.find { |candidate| candidate.pid == pid }
          next if child.nil?

          # Drain whatever the worker said before it exited. Its idle report and SIGCHLD race each other, and
          # the report is the only thing that knows a response was already written — without this, a worker
          # that answered and exited in the same breath gets reported as a death.
          while !child.control.socket.closed? && child.control.socket.wait_readable(0)
            child_reported child.control.socket
          end

          sweep_group child
          @children.delete child.slot.number
          answer_for child, status
          discard child
          child.control.close

          log.write "worker.reaped", pid: pid, slot: child.slot.number, served: child.served,
                                     signal: signal_name(status), exit_code: status.exitstatus
        end
      rescue Errno::ECHILD
        nil
      end

      # A killed worker cannot report its own death, because RLIMIT_FSIZE and the deadline KILL are
      # enforced by a signal. So the supervisor holds its copy of every dispatched connection and writes
      # the verdict itself. Without this the cold side sees a bare end of stream and cannot tell a limit
      # breach from a crash.
      # A worker still holding a connection at reap time never answered: it reports itself idle after writing,
      # and that report is drained above. So this is the only thing that can answer, and whether it says the
      # input did this or the cell did turns on how the worker died.
      def answer_for(child, status)
        return child.connection&.close unless child.busy?

        cause = child.killed_for ||
                SIGNAL_CAUSES.fetch(signal_name(status), Codes::CRASHED)
        counters.record Codes::KILLED
        counters.record_kill cause

        log.write "worker.killed", pid: child.pid, slot: child.slot.number, cause: cause,
                                   signal: signal_name(status), duration_ms: Clock.ms_since(child.dispatched_at)

        answer child.connection,
               Failure.new(code: Codes::KILLED, cause: cause, signal: signal_name(status)),
               timing: { perform_ms: Clock.ms_since(child.dispatched_at) }
      end

      def answer(connection, failure, timing: {})
        connection.write_line Response.failed(failure, timing: timing).to_line
      rescue SystemCallError, IOError
        counters.cancelled!
      ensure
        connection.close
      end

      # A worker tells the supervisor when its operation asked for less than the cell allows, because the
      # supervisor never reads a request and cannot know. It may only ever narrow: the number the supervisor
      # enforces is the one thing an operation must not be able to widen, and this is the side that owns
      # invariant 6. Anything that is not a positive number is nonsense from the only process here running
      # untrusted code, and the cell's own maximum stands.
      def narrowed_deadline(reported)
        return configuration.limits.deadline unless reported.is_a?(Numeric) && reported.positive?

        [ reported, configuration.limits.deadline ].min
      end

      def signal_name(status)
        Signal.signame status.termsig if status.signaled?
      end

      def running
        @children.each_value.count(&:busy?)
      end

      def free_slot
        (0...configuration.concurrency).find { |number| !@children.key?(number) }
      end

      # A Unix socket is a filesystem object and `connect` needs write permission on it, so this mode is the
      # access control on speaking to a cell at all.
      #
      # The group is what grants it. An application is already in this cell's gid so that a worker can
      # re-open the descriptors it is handed, which every operation that gives a tool a filename needs — and
      # nothing outside that group has business speaking to a cell. So the group carries both, and world
      # write would give the socket away to anything else sharing either container.
      #
      # The group is therefore load-bearing rather than advisory: without it an application cannot connect
      # and every call is EACCES. `HotCell.describe_cells` catches that at boot.
      SOCKET_MODE = 0o660

      def listen(name)
        path = socket_path(name)
        File.unlink path if File.socket?(path)

        UNIXServer.new(path).tap { File.chmod SOCKET_MODE, path }
      end

      def socket_path(name)
        File.join directory, name
      end

      # The socket's file mode is the access control on connecting, and the two sides do not share a uid,
      # so 0600 by the cell is a bare EACCES at the app's first request. What actually contains this is the
      # mount topology: the directory is a volume mounted into exactly two containers, so "anyone who can
      # see this socket" is already "the app and the cell".
      def verify_socket_paths!
        SOCKETS.each do |name|
          path = socket_path(name)
          next if path.bytesize <= SUN_PATH_MAX

          raise ConfigurationError, "#{path} is #{path.bytesize} bytes and a Unix socket path on this " \
                                    "platform holds #{SUN_PATH_MAX}. Choose a shorter directory."
        end
      end

      # Refuse to boot rather than warn and serve. A host sysctl is invisible to the image and it silently
      # voids the guarantee, and a warning in a log is how a dead control stays dead. This is the one boot
      # check that is worth having now.
      #
      # **Accepted risk.** An unreadable file means this is not Linux or the kernel has no Yama, which is
      # development rather than a deployment with a broken precondition — so that warns instead. The second
      # of those is a real hole: on a Linux kernel built without Yama the file is absent, same-uid ptrace is
      # unrestricted, and invariant 8 is gone while this boots anyway. The premise is that the kernels this
      # deploys on ship Yama, so refusing to boot on an absent file would fail development far more often
      # than it would catch a broken host.
      def verify_ptrace_scope!
        unless File.readable?(@ptrace_scope_path)
          return log.write "cell.ptrace_scope_unknown", path: @ptrace_scope_path,
                                                        message: "cannot verify that a worker is unable to read a sibling's memory"
        end

        scope = File.read(@ptrace_scope_path).strip
        return unless scope == "0"

        raise ConfigurationError,
              "kernel.yama.ptrace_scope is 0 on this host, so one worker can read another request's memory " \
              "through /proc/<pid>/mem. No container flag can set it. Set it to 1 or higher and boot again."
      end

      def verify_limits!
        Limits::RESOURCES.each do |key, resource|
          wanted = configuration.limits[key]
          next if wanted.nil?

          _soft, hard = Process.getrlimit(resource)
          next if hard == Process::RLIM_INFINITY || hard >= wanted

          raise ConfigurationError, "#{key}: #{wanted} is above this process's hard limit of #{hard}, so " \
                                    "a worker could not set it"
        end
      end

      def prepare_directories
        FileUtils.mkdir_p directory

        configuration.concurrency.times do |number|
          slot = Slot.build(workspace, number)
          next if slot.prepare

          log.write "slot.uncleaned", slot: number, home: slot.directory,
                                      message: "an earlier boot's files are still here"
        end
      end

      def preload
        Registry.operations.each { |operation| operation.before_fork.each(&:call) }
      end


      def shutdown
        refuse_queue "the cell is stopping"
        @control_pending.each { |pending| pending.connection.close }
        @children.each_value { |child| child.control.close unless child.control.socket.closed? }
        @work&.close
        @control&.close
        SOCKETS.each { |name| File.unlink socket_path(name) if File.socket?(socket_path(name)) }

        log.write "cell.stopped", pid: Process.pid
      end
  end
end
