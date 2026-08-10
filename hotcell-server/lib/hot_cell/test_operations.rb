# frozen_string_literal: true

require "digest"

# Fixture operations, so the whole surface can be exercised with no converter installed and no container
# running. haystack#8538 does the same thing with a scripted stand-in for soffice, which lets it test the
# whole surface in milliseconds.
#
# They ship rather than sitting in this gem's own test directory, for the reason hot_cell/test_cell.rb does:
# hotcell-client boots a real cell and needs a consist to point it at. It had written its own, and five of
# those answered to wire names these already claim — so `test.uppercase` meant one thing when the client
# suite proved it and another when this one did.
#
# Namespaced because this is a shipped file and `Fixtures` at the top level belongs to the application. Both
# suites alias it in their own helper.
module HotCell
  module Fixtures
    class Uppercase < HotCell::Operation
      operation "test.uppercase"

      def perform(inputs, outputs, _payload)
        source, = inputs
        destination, = outputs
        File.binwrite destination.path, File.binread(source.path).upcase

        { bytes: File.size(destination.path) }
      end
    end

    # Two inputs, one output, so the request shape with several inputs is covered.
    class Concatenate < HotCell::Operation
      operation "test.concatenate"

      def perform(inputs, outputs, payload)
        destination, = outputs
        File.binwrite destination.path, inputs.map { |input| File.binread(input.path) }.join(payload[:separator].to_s)

        { inputs: inputs.size }
      end
    end

    # Analysis: metadata out and no bytes, which is the shape with no outputs at all.
    class Measure < HotCell::Operation
      operation "test.measure"

      def perform(inputs, _outputs, payload)
        source, = inputs

        { bytes: File.size(source.path), digest: Digest::SHA256.file(source.path).hexdigest[0, 8],
          asked_for: payload[:asked_for] }
      end
    end

    # No inputs and no outputs, like rendering an initials avatar from nothing but a payload.
    class Echo < HotCell::Operation
      operation "test.echo"

      def perform(_inputs, _outputs, payload)
        { echoed: payload }
      end
    end

    class WhoAmI < HotCell::Operation
      operation "test.whoami"

      def perform(_inputs, _outputs, _payload)
        { pid: Process.pid, home: ENV["HOME"], scratch: Dir.exist?(scratch_path) }
      end

      private
        def scratch_path
          File.join ENV["HOME"].to_s, "..", "scratch"
        end
    end

    # An operation that reads what a caller gave it without a copy onto scratch, which is what an operation
    # reading only a container header wants rather than a multi-gigabyte copy.
    class Reverse < HotCell::Operation
      operation "test.reverse"
      stage :descriptors

      def perform(inputs, outputs, _payload)
        outputs.first.to_io.write inputs.first.to_io.read.reverse

        { staged: !inputs.first.staged? }
      end
    end

    class Broken < HotCell::Operation
      operation "test.broken"

      def perform(_inputs, _outputs, _payload)
        raise "the operation itself is broken"
      end
    end

    class Undecodable < HotCell::Operation
      operation "test.undecodable"

      def perform(_inputs, _outputs, _payload)
        raise HotCell::UnreadableInput, "not an image at all"
      end
    end

    # A library exception an operation declares as meaning "the input could not be decoded", the way the
    # Active Storage operations will declare Vips::Error.
    class LibraryError < StandardError; end

    class DeclaredUnreadable < HotCell::Operation
      operation "test.declared_unreadable"
      unreadable LibraryError

      def perform(_inputs, _outputs, _payload)
        raise LibraryError, "the library says no"
      end
    end

    class Hungry < HotCell::Operation
      operation "test.hungry"

      def perform(_inputs, _outputs, _payload)
        raise HotCell::MemoryExhausted, "out of memory -- size == 732MB"
      end
    end

    class BadResult < HotCell::Operation
      operation "test.bad_result"

      def perform(_inputs, _outputs, _payload)
        "a String is not a result"
      end
    end

    class UnserializableResult < HotCell::Operation
      operation "test.unserializable_result"

      def perform(_inputs, _outputs, _payload)
        { format: :png }
      end
    end

    # Returns without writing anything, which is how a full tmpfs arrives too.
    class Silent < HotCell::Operation
      operation "test.silent"

      def perform(_inputs, _outputs, _payload)
        {}
      end
    end

    class Overflowing < HotCell::Operation
      operation "test.overflowing"

      def perform(_inputs, outputs, payload)
        File.open(outputs.first.path, "wb") do |file|
          payload.fetch(:megabytes).times { file.write "x" * (1024 * 1024) }
          file.flush
        end

        {}
      end
    end

    # Pins the worker where Ruby cannot interrupt it.
    #
    # A deadline test built on sleep passes against a self-enforcing implementation that could never work in
    # production, because Timeout raises at an interrupt checkpoint and a thread inside a C extension does
    # not reach one until it returns. libvips is the real case; Integer#** is the one in the standard
    # library. Measured: 3 ** 40_000_000 runs for 6.7 seconds straight through a 0.05 second Timeout, so a
    # deadline test against it fails loudly rather than passing by finishing early.
    class Uninterruptible < HotCell::Operation
      operation "test.uninterruptible"
      EXPONENT = 40_000_000

      # The premise, asserted rather than assumed. If a later Ruby adds an interrupt check to this path, the
      # deadline tests should say so instead of quietly becoming weaker.
      def self.blocks_through_a_timeout?
        require "timeout"
        Timeout.timeout(0.05) { 3**5_000_000 }
        true
      rescue Timeout::Error
        false
      end

      def perform(_inputs, _outputs, _payload)
        { digits: (3**EXPONENT).bit_length }
      end
    end

    # Starts a grandchild that outlives the worker, and reports its pid so a test can ask whether the
    # deadline reached it. `spawn` rather than a converter, so this needs no toolchain installed.
    class Spawns < HotCell::Operation
      operation "test.spawns"

      def perform(_inputs, _outputs, _payload)
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

    # Reports what an exec'd converter can see of its environment, and what the worker itself can see, so a
    # test can prove the canary was really there before proving the converter never got it.
    class Environment < HotCell::Operation
      operation "test.environment"

      def perform(_inputs, _outputs, payload)
        converted = convert "env", env: payload[:env] || {}

        { seen: converted.out.lines.map(&:chomp).sort, worker_saw: ENV[payload[:canary].to_s],
          ok: converted.ok? }
      end
    end

    # Prints far more than any sane capture, on the stream the payload names, then exits. For proving that
    # a noisy converter costs a bounded amount of this worker's memory rather than all of it.
    class Noisy < HotCell::Operation
      operation "test.noisy"

      def perform(_inputs, _outputs, payload)
        stream = payload[:stream] == "err" ? "STDERR" : "STDOUT"
        script = "40.times { #{stream}.write('x' * 1_000_000) }"
        converted = convert "ruby", "-e", script, capture: 1024

        { out: converted.out.bytesize, err: converted.err.bytesize, ok: converted.ok? }
      end
    end

    # Two operations that configure the same global, so a worker serving A, B, A can be asked what the
    # global says at the moment each one ran.
    CONFIGURED = []

    class ConfiguresGlobal < HotCell::Operation
      abstract_operation

      def perform(_inputs, _outputs, _payload)
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

      def perform(_inputs, outputs, _payload)
        File.binwrite outputs.first.path, "only the first"

        { wrote: 1 }
      end
    end

    class Rlimits < HotCell::Operation
      operation "test.rlimits"

      def perform(_inputs, _outputs, _payload)
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

      def perform(_inputs, _outputs, payload)
        { bytes: ("x" * (payload.fetch(:megabytes) * 1024 * 1024)).bytesize }
      end
    end

    # A result carrying bytes a converter produced, which is where invalid UTF-8 comes from in practice.
    class Mojibake < HotCell::Operation
      operation "test.mojibake"

      def perform(_inputs, _outputs, _payload)
        { filename: "caf\xFF.jpg".dup.force_encoding(Encoding::UTF_8) }
      end
    end

    # Dies mid-request without answering and without a signal, which is what a cell fault looks like as
    # distinct from an input fault.
    class Vanishes < HotCell::Operation
      operation "test.vanishes"

      def perform(_inputs, _outputs, _payload)
        exit! 3
      end
    end

    class Blocking < HotCell::Operation
      operation "test.blocking"

      def perform(_inputs, _outputs, payload)
        sleep payload.fetch(:seconds)

        { slept: payload[:seconds], pid: Process.pid }
      end
    end
  end
end
