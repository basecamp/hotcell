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
                       :retired) do
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

    attr_reader :configuration, :counters, :log, :directory, :workspace

    def initialize(directory:, workspace: nil, configuration: HotCell.configuration, log: Log.new)
      @directory = directory
      @workspace = workspace || File.join(Dir.tmpdir, "hotcell-workspace")
      @configuration = configuration
      @log = log
      @children = {}
      @queue = []
      @counters = Counters.new
      @stopping = false
    end

    def boot
      verify_socket_paths!
      verify_limits!
      prepare_directories
      preload
      @work = listen "work.sock"
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
          list << @work unless @stopping
        end
      end

      # The nearest thing that needs doing without anybody knocking: a deadline, or a queued connection
      # that has waited long enough to be told so.
      def wait_for
        now = Clock.now
        nearest = [ *@children.each_value.filter_map(&:expires_at),
                    *@queue.map { |(_, queued_at)| queued_at + configuration.queue_wait } ].min
        return nil if nearest.nil?

        [ nearest - now, 0 ].max
      end

      def handle(source)
        case source
        when @signals then drain_signals
        when @work then accept_work
        else child_reported source
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

      def pump
        return if @stopping

        while @queue.any? && (child = available_child)
          connection, queued_at = @queue.shift
          dispatch child, connection, Clock.ms_since(queued_at)
        end
      end

      def dispatch(child, connection, queued_ms)
        child.connection = connection
        child.dispatched_at = Clock.now
        child.deadline = configuration.limits.deadline
        child.killed_for = nil
        child.served += 1

        child.control.send_message JSON.generate({ queued_ms: queued_ms }) << "\n",
                                   descriptors: [ connection ]
      end

      def available_child
        @children.each_value.find(&:available?) || spawn
      end

      def spawn
        number = free_slot or return nil
        slot = Slot.build(workspace, number)
        supervisor_side, worker_side = UNIXSocket.pair(:STREAM)

        pid = fork do
          become_worker supervisor_side
          Worker.new(slot: slot, configuration: configuration, control: Connection.new(worker_side),
                     log: log).run
        end

        worker_side.close
        log.write "worker.forked", pid: pid, slot: number

        @children[number] = Child.new(slot, pid, Connection.new(supervisor_side), nil, nil,
                                      configuration.limits.deadline, 0, nil, false)
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

        @children.each_value do |child|
          child.control.close
          child.connection&.close
        end
        @queue.each { |(connection, _)| connection.close }
      end

      def child_reported(socket)
        child = @children.each_value.find { |candidate| candidate.control.socket == socket }
        return if child.nil?

        line = child.control.read_line(limit: Worker::DISPATCH_BYTES)
        return child.control.close if line.nil?

        message = Payload.parse(line)
        if message[:deadline]
          child.deadline = message[:deadline]
        elsif message[:idle]
          finish child, message[:code]
        end
      rescue MessageError, JSON::ParserError => error
        log.write "worker.unreadable_report", pid: child&.pid, message: Failure.sanitize(error.message)
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
      def answer_for(child, status)
        return child.connection&.close if status.success?
        return unless child.busy?

        limit = child.killed_for || SIGNAL_LIMITS.fetch(signal_name(status), "signal")
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
        @children.each_value { |child| child.control.close unless child.control.socket.closed? }
        @work&.close
        SOCKETS.each { |name| File.unlink socket_path(name) if File.socket?(socket_path(name)) }

        log.write "cell.stopped", pid: Process.pid
      end
  end
end
