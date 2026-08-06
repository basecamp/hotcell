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
    Child = Struct.new(:slot, :pid, :control, :connection, :dispatched_at, :deadline, :served, :killed_for,
                       :retired, :buffer) do
      def busy?
        !connection.nil?
      end

      def available?
        !busy? && !retired
      end

      def overdue?(now)
        busy? && now - dispatched_at >= deadline
      end

      def expires_at
        dispatched_at + deadline if busy?
      end
    end

    # A path longer than this fails to bind with an error that does not say so. Darwin allows four fewer
    # bytes than Linux, and control.sock is the longer of the two names, so it overflows first.
    SUN_PATH_MAX = RUBY_PLATFORM.include?("darwin") ? 104 : 108

    # A cgroup kill and a deadline kill both arrive as SIGKILL, and a worker that dies on its own
    # out-of-memory path takes SIGSEGV or SIGABRT — libvips dereferences null there after printing the
    # correct diagnostic, and GLib's non-nullable g_malloc aborts. So all of these mean memory, and the
    # deadline is told apart by the supervisor knowing it sent that signal itself.
    SIGNAL_LIMITS = {
      "XFSZ" => "fsize",
      "SEGV" => "memory",
      "ABRT" => "memory",
      "TRAP" => "memory",
      "KILL" => "memory",
    }.freeze

    SOCKETS = [ "work.sock", "control.sock" ].freeze

    # Request memory is protected by kernel.yama.ptrace_scope >= 1, and nothing else protects it. That is a
    # host sysctl no container flag can supply.
    PTRACE_SCOPE = "/proc/sys/kernel/yama/ptrace_scope"

    # A cell that has loaded an application framework has loaded its configuration, and probably its
    # credentials with it. The thing that breaks this is a transitive require in somebody's operation rather
    # than anything here, which is why it is a check at boot instead of a test.
    #
    # Keyed on a constant only the framework itself defines, rather than on the top-level name. A gem that
    # serves Active Storage may reasonably namespace itself under ActiveStorage without linking against it —
    # activestorage-hotcell-server does exactly that, and the name says which consumer it serves rather than
    # what it loads. Module#const_defined? counts an autoload as defined without triggering it, so a framework
    # that is merely on the load path with its autoloads registered is still caught.
    FRAMEWORKS = {
      "ActiveRecord" => :Base,
      "ActiveStorage" => :Blob,
      "ActionController" => :Base,
      "ActionMailer" => :Base,
      "ActionCable" => :Server,
    }.freeze

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
      verify_no_framework!
      @work = listen "work.sock"
      @control = listen "control.sock"
      @control_handler = Control.new(configuration: configuration, counters: counters)
      trap_signals

      log.write "cell.boot", pid: Process.pid, directory: directory, operations: Registry.names,
                             **configuration.to_h
      warn_about_reuse
      self
    end

    def run
      until stopped?
        readable, = IO.select(sources, nil, nil, wait_for)
        Array(readable).each { |source| handle source }

        enforce_deadlines
        expire_queue
        expire_control
        retire_idle if @stopping
        pump
      end
    ensure
      shutdown
    end

    def stop
      @stopping = true
    end

    def stopped?
      @stopping && @children.empty?
    end

    private
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
          pending_control(source) ? read_control(source) : child_reported(source)
        end
      end

      # Reap on SIGCHLD, not at the top of the accept loop. A worker killed by a resource limit cannot
      # report its own death, so the supervisor reports it — and a supervisor that only reaps when the next
      # connection arrives never reports it on an idle cell, leaving the caller to wait out its whole
      # timeout for a worker that died in the first second.
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

      def accept_work
        socket = @work.accept_nonblock(exception: false)
        return if socket == :wait_readable

        connection = Connection.new(socket)

        if running < configuration.concurrency || @queue.size < configuration.queue_size
          @queue << [ connection, Clock.now ]
          counters.observe_queue @queue.size
        else
          refuse connection, "the queue is full at #{@queue.size}"
        end
      end

      def accept_control
        socket = @control.accept_nonblock(exception: false)
        return if socket == :wait_readable

        connection = Connection.new(socket)

        if @control_pending.size >= CONTROL_BACKLOG
          answer connection, Failure.new(code: "capacity", message: "#{CONTROL_BACKLOG} control connections are already waiting")
        else
          @control_pending << Pending.new(connection, Clock.now, "".b)
        end
      end

      def pending_control(socket)
        @control_pending.find { |pending| pending.connection.socket == socket }
      end

      # Keep whatever arrived and come back for the rest. A stream socket does not promise the whole line
      # lands in one read, and a blocking read here would put the loop at the mercy of a control client.
      def read_control(socket)
        pending = pending_control(socket)
        chunk = socket.read_nonblock(MAX_REQUEST_BYTES, exception: false)
        return if chunk == :wait_readable

        return drop_control(pending) if chunk.nil?

        pending.buffer << chunk

        if pending.buffer.include?("\n")
          @control_pending.delete pending
          answer_control pending.connection, pending.buffer.force_encoding(Encoding::UTF_8)
        elsif pending.buffer.bytesize > MAX_REQUEST_BYTES
          @control_pending.delete pending
          answer pending.connection, Failure.new(code: "invalid", message: "control message with no newline")
        end
      end

      # A control answer that cannot be serialized must not take the cell down with it. This channel exists to
      # be available when nothing else is, and it runs inside the loop every conversion depends on — so
      # anything raised while answering a scrape would stop the cell serving.
      #
      # **Unproven, on purpose.** `reuse: :unlimited` used to reach this, because a Symbol is not JSON-native
      # and a cell configured that way could not describe itself. Configuration#to_h now reports it as a
      # String, so nothing left in describe or metrics can raise here and no test can catch this rescue being
      # removed. There is no mutation for it, and it stays for the same reason as the buffered read above.
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
        child.connection = connection
        child.dispatched_at = Clock.now
        child.deadline = configuration.limits.deadline
        child.killed_for = nil
        child.served += 1

        child.control.send_message JSON.generate({ queued_ms: queued_ms }) << "\n",
                                   descriptors: [ connection ]
        true
      rescue SystemCallError, IOError => error
        log.write "worker.undispatchable", pid: child.pid, slot: child.slot.number,
                                           error: error.class.name
        child.connection = nil
        child.retired = true
        answer connection, Failure.new(code: Codes::KILLED, limit: "crashed", message: error.message)
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

        @children[number] = Child.new(slot, pid, Connection.new(supervisor_side), nil, nil,
                                      configuration.limits.deadline, 0, nil, false, "".b)
      end

      # Everything the supervisor holds and the worker must not: the listener, the signal pipe, the other
      # children's control sockets, and every connection the supervisor is still holding for somebody else.
      # The connection this worker is about to serve arrives over SCM_RIGHTS a moment from now, so closing
      # the inherited copy here costs nothing and stops it lingering for the worker's whole life.
      def become_worker(supervisor_side)
        [ "CHLD", "INT", "TERM" ].each { |signal| trap signal, "DEFAULT" }

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
      # **Unproven, on purpose.** Neither hazard has a reachable trigger: a report is one small write, well
      # under PIPE_BUF, and 160 requests across four concurrent callers at reuse 8 never coalesced two of them
      # into one read. So there is no mutation for this — one that nothing catches would fail the mutation
      # task forever. It stays because it closes a whole class of cell death for a few lines.
      def child_reported(socket)
        child = @children.each_value.find { |candidate| candidate.control.socket == socket }
        return if child.nil?

        chunk = socket.read_nonblock(Worker::DISPATCH_BYTES, exception: false)
        return if chunk == :wait_readable

        # End of stream means the worker is gone. Retire it as well as closing, or it stays eligible for the
        # next dispatch until the reap catches up.
        if chunk.nil?
          child.retired = true
          return child.control.close
        end

        child.buffer << chunk

        while (newline = child.buffer.index("\n"))
          apply_report child, child.buffer.slice!(0, newline + 1).force_encoding(Encoding::UTF_8)
        end

        return if child.buffer.bytesize <= Worker::DISPATCH_BYTES

        log.write "worker.unreadable_report", pid: child.pid,
                                              message: "report passed #{Worker::DISPATCH_BYTES} bytes with no newline"
        child.buffer.clear
      end

      def apply_report(child, line)
        message = Payload.parse(line)
        if message[:deadline]
          child.deadline = narrowed_deadline(message[:deadline])
        elsif message[:idle]
          finish child, message[:code]
        end
      rescue MessageError, JSON::ParserError => error
        log.write "worker.unreadable_report", pid: child.pid, message: Failure.sanitize(error.message)
      end

      def finish(child, code)
        counters.record code
        child.connection&.close
        child.connection = nil
        child.dispatched_at = nil
        remove_scratch child.slot

        retire child if configuration.retire?(child.served)
      end

      # Closing the control socket is the retirement: the worker's next await_dispatch sees end of stream
      # and exits. The slot stays taken until the process is actually gone.
      def retire(child)
        child.retired = true
        child.control.close
      end

      def retire_idle
        @children.each_value.select(&:available?).each { |child| retire child }
      end

      def enforce_deadlines
        now = Clock.now

        @children.each_value.select { |child| child.overdue?(now) }.each do |child|
          child.killed_for = "deadline"
          log.write "worker.deadline", pid: child.pid, slot: child.slot.number, deadline: child.deadline

          begin
            Process.kill :KILL, child.pid
          rescue Errno::ESRCH
            nil
          end
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

          @children.delete child.slot.number
          answer_for child, status
          remove_scratch child.slot
          child.control.close

          log.write "worker.reaped", pid: pid, slot: child.slot.number, served: child.served,
                                     signal: signal_name(status), status: status.exitstatus
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

        limit = child.killed_for ||
                (status.signaled? ? SIGNAL_LIMITS.fetch(signal_name(status), "signal") : "crashed")
        counters.record Codes::KILLED
        counters.record_kill limit

        log.write "worker.killed", pid: child.pid, slot: child.slot.number, limit: limit,
                                   signal: signal_name(status), elapsed_ms: Clock.ms_since(child.dispatched_at)

        answer child.connection,
               Failure.new(code: Codes::KILLED, limit: limit, signal: signal_name(status)),
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

      def listen(name)
        path = socket_path(name)
        File.unlink path if File.socket?(path)

        UNIXServer.new(path).tap { File.chmod 0o666, path }
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
      # An unreadable file means this is not Linux or the kernel has no Yama, which is development rather
      # than a deployment with a broken precondition — so that warns instead.
      def verify_ptrace_scope!
        unless File.readable?(@ptrace_scope_path)
          return log.write "cell.ptrace_scope_unknown", path: @ptrace_scope_path,
                                                        warning: "cannot verify that a worker is unable to read a sibling's memory"
        end

        scope = File.read(@ptrace_scope_path).strip
        return unless scope == "0"

        raise ConfigurationError,
              "kernel.yama.ptrace_scope is 0 on this host, so one worker can read another request's memory " \
              "through /proc/<pid>/mem. No container flag can set it. Set it to 1 or higher and boot again."
      end

      def verify_no_framework!
        loaded = FRAMEWORKS.select do |framework, marker|
          Object.const_defined?(framework) && Object.const_get(framework).const_defined?(marker, false)
        end
        return if loaded.empty?

        raise ConfigurationError,
              "#{loaded.keys.join(", ")} is loaded in this cell, which means an operation required an " \
              "application framework — and a framework brings its configuration and its credentials. A cell " \
              "holds neither."
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
          FileUtils.mkdir_p slot.home, mode: 0o700
          remove_scratch slot
        end
      end

      def preload
        Registry.operations.each { |operation| operation.before_fork.each(&:call) }
      end

      def warn_about_reuse
        warning = configuration.in_process_warning(Registry.operations)
        log.write "cell.reuse_warning", warning: warning if warning
      end

      def remove_scratch(slot)
        FileUtils.remove_entry slot.scratch if Dir.exist?(slot.scratch)
      rescue SystemCallError
        nil
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
