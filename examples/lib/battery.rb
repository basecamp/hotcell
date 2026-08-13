# frozen_string_literal: true

require "tempfile"
require_relative "clients"

# One list of checks over the example operations, run against any cell that carries them: `rake
# test:devcell` points it at the native development process, and `bin/conformance` points it at a
# container. Every check drives through the thin client classes, the way an application would.
#
# The first failed check raises Battery::Failed with what was expected and what happened; the consumer
# decides what to do with a pass.
module Examples
  class Battery
    class Failed < StandardError; end

    MESSAGE = "a message that must come back through the caller's own descriptors"

    OPERATIONS = [ Echo, Sleep, Greedy, Overflow, Crash, Spawn, Probe, Isolation ].map(&:operation).freeze

    # `memory_enforceable: false` skips the memory-clamp check, for platforms where RLIMIT_DATA cannot be
    # set (macOS). `isolation: true` adds the checks only a containerized cell can pass.
    def initialize(cell:, memory_enforceable: true, isolation: false, out: $stdout)
      @cell = cell
      @memory_enforceable = memory_enforceable
      @isolation = isolation
      @out = out
    end

    def run
      check("describe lists the example operations") { describe }
      check("echo round-trips through the caller's descriptors") { echo }
      check("a sleep past the deadline is killed: deadline") { deadline }

      if @memory_enforceable
        check("an allocation past the memory limit is killed: memory") { memory }
      else
        @out.puts "  skip the memory clamp (RLIMIT_DATA is not settable on this platform)"
      end

      check("an output past the file-size limit is killed: fsize") { file_size }
      check("an operation that raises answers failed") { crash_by_raise }
      check("a worker that dies by signal answers killed") { crash_by_signal }
      check("a spawned grandchild does not outlive its worker") { orphan }
      check("offered overload answers capacity") { overload }
      check("the cell keeps serving afterwards") { still_serving }
      check("metrics answer on the control socket") { metrics }
      check("the isolation holds") { isolation } if @isolation

      true
    end

    private
      def check(name)
        yield
        @out.puts "  ok #{name}"
      rescue Failed => error
        raise Failed, "#{name}: #{error.message}"
      end

      def describe
        @described = @cell.describe
        assert @described, "the cell did not answer describe"

        missing = OPERATIONS - Array(@described[:operations])
        assert missing.empty?, "the cell does not carry #{missing.inspect}"
      end

      def echo
        with_files do |input, output, output_path|
          result = Echo.perform_in_hotcell([ input ], [ output ])

          assert_equal MESSAGE, File.binread(output_path), "the echoed message"
          assert_equal false, result[:staged], "the input was staged onto scratch rather than passed"
        end
      end

      def deadline
        expect_failure @cell.transient, /\Akilled: deadline/ do
          Sleep.perform_in_hotcell [], [], { seconds: 30 }
        end
      end

      def memory
        expect_failure @cell.permanent, /\Akilled: memory/ do
          Greedy.perform_in_hotcell [], [], { megabytes: 900 }
        end
      end

      def file_size
        with_files do |_input, output|
          expect_failure @cell.permanent, /\Akilled: fsize/ do
            Overflow.perform_in_hotcell [], [ output ], { megabytes: 16 }
          end
        end
      end

      def crash_by_raise
        expect_failure @cell.transient, /\Afailed/ do
          Crash.perform_in_hotcell [], [], { mode: "raise" }
        end
      end

      def crash_by_signal
        expect_failure @cell.transient, /\Akilled/ do
          Crash.perform_in_hotcell [], [], { mode: "signal" }
        end
      end

      def orphan
        pid = Spawn.perform_in_hotcell([], [])[:pid]

        gone = within(10) { !Probe.perform_in_hotcell([], [], { pid: pid })[:alive] }
        assert gone, "the grandchild (pid #{pid}) outlived its worker"
      end

      # Fills every worker and every queue place with sleeps, then offers one more. The blockers' own
      # outcomes are deliberately not asserted: the queued ones may run or may wait, and either way the
      # cell is full when the last request arrives.
      def overload
        places = @described.fetch(:concurrency) + @described.fetch(:queue_size)
        blockers = places.times.map do
          Thread.new do
            Sleep.perform_in_hotcell [], [], { seconds: 2 }
          rescue StandardError
            nil
          end
        end

        begin
          sleep 0.5
          expect_failure @cell.transient, /\Acapacity/ do
            Sleep.perform_in_hotcell [], [], { seconds: 2 }
          end
        ensure
          blockers.each(&:join)
        end
      end

      def still_serving
        with_files do |input, output, output_path|
          Echo.perform_in_hotcell [ input ], [ output ]

          assert_equal MESSAGE, File.binread(output_path), "the echoed message"
        end
      end

      def metrics
        response = @cell.metrics
        assert response&.ok?, "the control socket did not answer metrics: #{response&.failure}"
        assert response.result[:requests].is_a?(Hash), "metrics carried no request counts"
      end

      def isolation
        result = Isolation.perform_in_hotcell([], [])

        assert_equal [ "lo" ], result[:interfaces], "the cell's network interfaces"
        assert_equal false, result[:writable_root], "the cell's root filesystem took a write"
        assert_equal true, result[:scratch_noexec], "the cell's scratch is not mounted noexec"

        assert result[:tool_env], "the env tool could not run inside the cell"
        extra = result[:tool_env] - %w[ HOME LANG LC_ALL PATH ]
        assert_equal [], extra, "an exec'd tool sees more than the written environment"
      end

      def assert(condition, message)
        raise Failed, message unless condition
      end

      def assert_equal(expected, actual, subject)
        assert expected == actual, "#{subject}: expected #{expected.inspect}, got #{actual.inspect}"
      end

      def expect_failure(expected_class, matching)
        yield
        raise Failed, "expected #{matching.inspect} and the call succeeded"
      rescue expected_class => error
        assert error.message.match?(matching), "expected #{matching.inspect}, got: #{error.message}"
        error
      end

      # A written input and an empty output, opened with the access mode each descriptor demands: an
      # Input travels read-only and an Output write-only, which is why the Tempfiles themselves — always
      # read-write — cannot be what goes over the socket.
      def with_files
        Tempfile.create("battery-input", binmode: true) do |staging|
          staging.write MESSAGE
          staging.flush

          Tempfile.create("battery-output", binmode: true) do |sink|
            File.open(staging.path, "rb") do |input|
              File.open(sink.path, "wb") do |output|
                yield input, output, sink.path
              end
            end
          end
        end
      end

      def within(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

        loop do
          return true if yield
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.1
        end
      end
  end
end
