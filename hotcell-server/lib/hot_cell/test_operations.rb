# frozen_string_literal: true

require "digest"
require "fcntl"
require "fileutils"

# Fixture operations, so the whole surface can be exercised in milliseconds, with no tool installed and no
# container running.
#
# They ship rather than sitting in this gem's own test directory, for the reason hot_cell/test_cell.rb does:
# hotcell-client boots a real cell and needs an inventory to point it at. It had written its own, and five of
# those answered to routing names these already claim — so `test.uppercase` meant one thing when the client
# suite proved it and another when this one did.
#
# Namespaced because this is a shipped file and `Fixtures` at the top level belongs to the application. Both
# suites alias it in their own helper.
module HotCell
  module Fixtures
    class Uppercase < HotCell::Operation
      operation "test.uppercase"

      def perform(inputs, outputs)
        source, = inputs
        destination, = outputs
        File.binwrite destination.path, File.binread(source.path).upcase

        { bytes: File.size(destination.path) }
      end
    end

    # Two inputs, one output, so the request shape with several inputs is covered.
    class Concatenate < HotCell::Operation
      operation "test.concatenate"

      def perform(inputs, outputs, separator: "")
        destination, = outputs
        File.binwrite destination.path, inputs.map { |input| File.binread(input.path) }.join(separator.to_s)

        { inputs: inputs.size }
      end
    end

    # Analysis: metadata out and no bytes, which is the shape with no outputs at all.
    class Measure < HotCell::Operation
      operation "test.measure"

      def perform(inputs, _outputs, asked_for: nil)
        source, = inputs

        { bytes: File.size(source.path), digest: Digest::SHA256.file(source.path).hexdigest[0, 8],
          asked_for: asked_for }
      end
    end

    # No inputs and no outputs, like rendering an initials avatar from nothing but a payload.
    class Echo < HotCell::Operation
      operation "test.echo"

      def perform(_inputs, _outputs, **payload)
        { echoed: payload }
      end
    end

    class WhoAmI < HotCell::Operation
      operation "test.whoami"

      def perform(_inputs, _outputs)
        { pid: Process.pid, home: ENV["HOME"] }
      end
    end

    # Leaves its $HOME in a state the worker cannot remove, by taking write permission off a subdirectory
    # that still has a file in it. A tool running as this user can do the same to a sibling's directory,
    # which is why a removal that fails has to be reported rather than swallowed.
    class UnremovableHome < HotCell::Operation
      operation "test.unremovable_home"

      def perform(_inputs, _outputs)
        blocked = File.join(ENV["HOME"].to_s, "blocked")
        FileUtils.mkdir_p blocked
        File.write File.join(blocked, "file"), "x"
        File.chmod 0o500, blocked

        { blocked: blocked }
      end
    end

    # Leaves a file in $HOME and says whether an earlier request already left one. A tool reads its
    # configuration from $HOME and a configuration file is executable — ImageMagick runs the command lines
    # in delegates.xml and applies the rights in policy.xml — so a home that outlives its request lets one
    # compromised conversion reconfigure every later one on that slot. See adr/0003.
    class HomeMarker < HotCell::Operation
      operation "test.home_marker"

      def perform(_inputs, _outputs)
        found = File.exist?(marker)
        File.write marker, "planted"

        { found: found, home: ENV["HOME"] }
      end

      private
        def marker
          File.join ENV["HOME"].to_s, "planted-by-an-earlier-request"
        end
    end

    # An operation that reads what a caller gave it without a copy onto scratch: it never asks for a path,
    # which is what an operation reading only a container header wants rather than a multi-gigabyte copy.
    class Reverse < HotCell::Operation
      operation "test.reverse"

      def perform(inputs, outputs)
        outputs.first.to_io.write inputs.first.to_io.read.reverse

        { copied: inputs.first.staged? }
      end
    end

    class Broken < HotCell::Operation
      operation "test.broken"

      def perform(_inputs, _outputs)
        raise "the operation itself is broken"
      end
    end

    # Raises past `serve`, which rescues StandardError, so it reaches `run` — the only path that writes
    # `worker.crashed`. `test.broken` cannot get there: an ordinary error is answered on the connection.
    class Fatal < HotCell::Operation
      operation "test.fatal"

      def perform(_inputs, _outputs)
        raise Exception, "a worker cannot answer for this one"
      end
    end

    # Hangs in its boot hook, which runs before the worker reports its operation. So the supervisor kills a
    # worker whose operation it never learned, which is the case `worker.killed` must leave unnamed rather
    # than fill in with whatever this slot served last.
    class SlowBoot < HotCell::Operation
      operation "test.slow_boot"
      before_worker_boot { sleep 60 }

      def perform(_inputs, _outputs)
        {}
      end
    end

    class Undecodable < HotCell::Operation
      operation "test.undecodable"

      def perform(_inputs, _outputs)
        raise HotCell::UnreadableInput, "not an image at all"
      end
    end

    # A library exception an operation declares as meaning "the input could not be decoded", the way the
    # Active Storage operations will declare Vips::Error.
    class LibraryError < StandardError; end

    class DeclaredUnreadable < HotCell::Operation
      operation "test.declared_unreadable"
      unreadable LibraryError

      def perform(_inputs, _outputs)
        raise LibraryError, "the library says no"
      end
    end

    class Hungry < HotCell::Operation
      operation "test.hungry"

      def perform(_inputs, _outputs)
        raise HotCell::MemoryExhausted, "out of memory -- size == 732MB"
      end
    end

    # A tool spawn that fails because the host is out of memory. fork raises Errno::ENOMEM under host
    # pressure, before the tool has read a byte of the input, so this is the cell having a bad moment
    # rather than a decompression bomb — and it must not be recorded as a permanent memory verdict.
    class StarvedSpawn < HotCell::Operation
      operation "test.starved_spawn"

      def perform(_inputs, _outputs)
        raise Errno::ENOMEM, "Cannot allocate memory - fork(2)"
      end
    end

    class SignalsSibling < HotCell::Operation
      operation "test.signals_sibling"

      # Workers share a uid and a pid namespace, so one finds another by looking for a process the
      # supervisor also fathered. This is the reproducer for the forged verdict: nothing here touches the
      # victim's input, and the victim is holding an unrelated one.
      def perform(_inputs, _outputs, signal:)
        sibling = siblings.first
        Process.kill signal, sibling if sibling

        { signalled: sibling }
      end

      private
        # Two ways to ask the same question, because the suite runs on macOS as well and only one of them
        # has /proc. An attacker inside a cell has whichever the image gives it; the point of the reproducer
        # is that the answer is obtainable at all.
        def siblings
          pids = Dir.exist?("/proc") ? procfs_children : ps_children

          pids.reject { |pid| pid == Process.pid }
        end

        def procfs_children
          Dir.glob("/proc/[0-9]*").filter_map do |path|
            status = File.read(File.join(path, "status"))
            File.basename(path).to_i if status[/^PPid:\s+(\d+)/, 1].to_i == Process.ppid
          rescue SystemCallError
            nil
          end
        end

        def ps_children
          `ps -A -o pid=,ppid=`.lines.filter_map do |line|
            pid, ppid = line.split.map(&:to_i)
            pid if ppid == Process.ppid
          end
        end
    end

    # Spawns a process and does not wait for it, the way a worker that crashed mid-request would leave a
    # tool behind. The spawned process inherits the worker's process group, so the supervisor's group sweep
    # at reap is what must kill it — nothing else is watching it, and it has no deadline. Returns the pid so
    # a test can watch for it.
    class Orphaner < HotCell::Operation
      operation "test.orphaner"

      def perform(_inputs, _outputs)
        { spawned: Process.spawn("sleep", "300") }
      end
    end

    class BadResult < HotCell::Operation
      operation "test.bad_result"

      def perform(_inputs, _outputs)
        "a String is not a result"
      end
    end

    class UnserializableResult < HotCell::Operation
      operation "test.unserializable_result"

      def perform(_inputs, _outputs)
        { format: :png }
      end
    end

    # Returns without writing anything, which is how a full tmpfs arrives too.
    class Silent < HotCell::Operation
      operation "test.silent"

      def perform(_inputs, _outputs)
        {}
      end
    end

    class Overflowing < HotCell::Operation
      operation "test.overflowing"

      def perform(_inputs, outputs, megabytes:)
        File.open(outputs.first.path, "wb") do |file|
          megabytes.times { file.write "x" * (1024 * 1024) }
          file.flush
        end

        {}
      end
    end

    # Pins the worker where Ruby cannot interrupt it.
    #
    # A deadline test built on sleep passes against a self-enforcing implementation that could never work in
    # production, because Timeout raises at an interrupt checkpoint and a thread inside a C extension does
    # not reach one until it returns. libvips is the real case. Deferring the raise reproduces that on every
    # Ruby and every build, which a long computation cannot: Integer#** takes seven seconds without GMP and
    # a fraction of a second with it. SIGKILL is not deferrable, so the supervisor still gets through.
    class Uninterruptible < HotCell::Operation
      operation "test.uninterruptible"
      SECONDS = 60

      def perform(_inputs, _outputs)
        Thread.handle_interrupt(Exception => :never) { sleep SECONDS }
        {}
      end
    end

    # Starts a grandchild that outlives the worker, and reports its pid so a test can ask whether the
    # deadline reached it. `spawn` rather than a tool, so this needs no toolchain installed.
    class Spawns < HotCell::Operation
      operation "test.spawns"

      def perform(_inputs, _outputs)
        pid = spawn("sleep", "60")
        tell_and_wait pid
      end

      private
        def tell_and_wait(pid)
          File.write ENV.fetch("HOTCELL_SPAWNED_PID_PATH"), pid.to_s
          sleep 60
          { pid: pid }
        end
    end

    # Declares less than the cell allows, so the supervisor has to learn the narrower number from the worker
    # rather than from the request it never reads.
    class Impatient < Uninterruptible
      operation "test.impatient"
      limits deadline: 1
    end

    # Declares more than the cell allows, which the cell clamps. Invariant 6.
    class Patient < Uninterruptible
      operation "test.patient"
      limits deadline: 300
    end

    # Hands an exec'd tool the input descriptor and has it read the bytes back through /dev/fd, so a test
    # can prove run_tool's `pass:` exposes a descriptor to a tool without staging it. Reports whether the
    # input was copied onto scratch, which must be false.
    class ReadThroughFd < HotCell::Operation
      operation "test.read_through_fd"

      def perform(inputs, _outputs)
        source, = inputs
        result = run_tool "cat", source.fd_path, pass: [ source.to_io ]

        { content: result.out, ok: result.ok?, staged: source.staged? }
      end
    end

    # Reports what an exec'd tool can see of its environment, and what the worker itself can see, so a
    # test can prove the canary was really there before proving the tool never got it.
    class Environment < HotCell::Operation
      operation "test.environment"

      def perform(_inputs, _outputs, env: {}, canary: nil)
        result = run_tool "env", env: env

        { seen: result.out.lines.map(&:chomp).sort, worker_saw: ENV[canary.to_s],
          ok: result.ok? }
      end
    end

    # Prints far more than any sane capture, on the stream the payload names, then exits. For proving that
    # a noisy tool costs a bounded amount of this worker's memory rather than all of it.
    class Noisy < HotCell::Operation
      operation "test.noisy"

      def perform(_inputs, _outputs, stream: "out")
        stream = stream == "err" ? "STDERR" : "STDOUT"
        script = "40.times { #{stream}.write('x' * 1_000_000) }"
        result = run_tool "ruby", "-e", script, capture: 1024

        { out: result.out.bytesize, err: result.err.bytesize, ok: result.ok? }
      end
    end

    # Two operations that configure the same global, so a worker serving A, B, A can be asked what the
    # global says at the moment each one ran.
    CONFIGURED = []

    class ConfiguresGlobal < HotCell::Operation
      abstract_operation

      def perform(_inputs, _outputs)
        { configured_for: CONFIGURED.last }
      end
    end

    class ConfiguresAlpha < ConfiguresGlobal
      operation "test.configures_alpha"
      before_worker_boot { CONFIGURED << "alpha" }
    end

    class ConfiguresBeta < ConfiguresGlobal
      operation "test.configures_beta"
      before_worker_boot { CONFIGURED << "beta" }
    end

    # Writes the first output and leaves the second alone, which is a positive total and reads as success to
    # anything checking the aggregate.
    class HalfWritten < HotCell::Operation
      operation "test.half_written"

      def perform(_inputs, outputs)
        File.binwrite outputs.first.path, "only the first"

        { wrote: 1 }
      end
    end

    class Rlimits < HotCell::Operation
      operation "test.rlimits"

      def perform(_inputs, _outputs)
        { memory: Process.getrlimit(Process::RLIMIT_DATA), file_size: Process.getrlimit(Process::RLIMIT_FSIZE),
          open_files: Process.getrlimit(Process::RLIMIT_NOFILE), core: Process.getrlimit(Process::RLIMIT_CORE) }
      end
    end

    # Asks for less than the cell allows, so the soft limit narrows and the hard limit does not.
    class Frugal < Rlimits
      operation "test.frugal"
      limits memory: 1024 * 1024**2, file_size: 4 * 1024 * 1024, open_files: 64
    end

    # Asks for more than any cell will allow, on every limit. Unclamped, the worker would try to set a soft limit
    # above its own hard limit and die before it could answer.
    class Extravagant < Rlimits
      operation "test.extravagant"
      limits memory: 8 * 1024**3, file_size: 512 * 1024**2, open_files: 4096, deadline: 3600
    end

    class Greedy < HotCell::Operation
      operation "test.greedy"

      def perform(_inputs, _outputs, megabytes:)
        { bytes: ("x" * (megabytes * 1024 * 1024)).bytesize }
      end
    end

    # A result carrying bytes a tool produced, which is where invalid UTF-8 comes from in practice.
    class Mojibake < HotCell::Operation
      operation "test.mojibake"

      def perform(_inputs, _outputs)
        { filename: "caf\xFF.jpg".dup.force_encoding(Encoding::UTF_8) }
      end
    end

    # Dies mid-request without answering and without a signal, which is what a cell fault looks like as
    # distinct from an input fault.
    class Vanishes < HotCell::Operation
      operation "test.vanishes"

      def perform(_inputs, _outputs)
        exit! 3
      end
    end

    # Reports itself idle while its request is still running, so the report and the truth disagree from
    # that moment on. The control socket is private to the Worker, but it lives in the operation's own
    # process, so reaching it takes one ObjectSpace walk. With `exit_after`, the worker then exits without
    # ever reading its control socket again, so whatever the supervisor wrote there in the meantime is
    # queued and unread when it goes.
    class EarlyIdle < HotCell::Operation
      operation "test.early_idle"

      def perform(_inputs, _outputs, pid_path:, exit_after: nil)
        # The one with an open control socket, not `.first`: a suite that builds a Worker in its own
        # process leaves it on the heap for the fork to inherit, with its sockets closed by teardown.
        worker = ObjectSpace.each_object(HotCell::Worker).find do |candidate|
          !candidate.instance_variable_get(:@control).socket.closed?
        end
        worker.instance_variable_get(:@control).write_line JSON.generate(idle: true, code: "ok") << "\n"
        File.write pid_path, Process.pid.to_s

        if exit_after
          sleep exit_after
          exit! 0
        else
          sleep 300
        end
      end
    end

    class Blocking < HotCell::Operation
      operation "test.blocking"

      def perform(_inputs, _outputs, seconds:)
        sleep seconds

        { slept: seconds, pid: Process.pid }
      end
    end

    # Writes to fd 2 and then either dies the way a C library does — `exit()` with no Ruby exception, so
    # there is no `worker.crashed` line and nothing on the connection — or returns normally, which is the
    # warning a cell deliberately does not report. `noise:` goes out before `text:`, so a test can ask which
    # end of an oversized transcript was kept.
    class StderrWriter < HotCell::Operation
      operation "test.stderr_writer"

      def perform(_inputs, _outputs, text:, noise: 0, fatal: false)
        $stderr.write "noise\n" * noise
        $stderr.write text
        $stderr.flush
        exit! 1 if fatal

        { wrote: text.bytesize }
      end
    end

    # Bytes that are not valid UTF-8, which a payload cannot carry — so this is a fixture rather than an
    # argument to StderrWriter. A decoder writing a filename out of a hostile file is where these come from.
    class GarbledStderr < HotCell::Operation
      operation "test.garbled_stderr"

      def perform(_inputs, _outputs)
        $stderr.write "libgomp: \xFF\xFE failed\n".b
        $stderr.flush
        exit! 1
      end
    end

    # Reports whether fd 2 is non-blocking, which is the load-bearing decision behind the capture: a
    # blocking fd 2 would put the supervisor's scheduling in the middle of a libvips `write(2)`.
    class StderrFlags < HotCell::Operation
      operation "test.stderr_flags"

      def perform(_inputs, _outputs)
        { nonblock: ($stderr.fcntl(Fcntl::F_GETFL) & Fcntl::O_NONBLOCK).positive? }
      end
    end

    # A tool that keeps writing to fd 2 after the worker itself is gone. fd 2 is never close-on-exec, so
    # everything a worker spawned holds the write end, and the pipe reports no end of stream until the
    # reap's group sweep kills them.
    class StderrDescendant < HotCell::Operation
      operation "test.stderr_descendant"

      def perform(_inputs, _outputs)
        spawn "sh", "-c", "while :; do echo from the descendant >&2; done"
        sleep 0.5
        exit! 1
      end
    end
  end
end
