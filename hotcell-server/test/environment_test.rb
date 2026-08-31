# frozen_string_literal: true

require "test_helper"

# Invariant 9, and the one thing about a cell's environment that is actually under our control.
#
# A worker is forked, so its own /proc/self/environ is the exec-time environment of the process it came from,
# and ENV.delete changes nothing a sibling worker can read. An exec'd child is different: it gets a fresh
# environ, and that is the only point where we choose what a tool sees.
#
# `unsetenv_others: true` is one keyword whose removal changes nothing observable in normal operation, which
# is exactly why it is tested.
class EnvironmentTest < HotCellServerTest
  CANARY = "HOTCELL_ENVIRONMENT_TEST_CANARY"

  def test_a_tool_sees_only_what_its_operation_wrote_for_it
    with_canary do
      TestCell.boot do |cell|
        result = assert_ok(cell.call("test.environment",
                                     payload: { canary: CANARY, env: { "TOOL_SETTING" => "yes" } })).result

        # The premise first: the worker really did inherit the canary, so its absence below means something.
        assert_equal "must-not-leak", result[:worker_saw]

        assert_includes result[:seen], "TOOL_SETTING=yes"
        assert_empty result[:seen].grep(/#{CANARY}/),
                     "the tool inherited the worker's environment"
      end
    end
  end

  def test_a_tool_gets_the_slots_home_rather_than_the_callers
    with_canary do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment", payload: { canary: CANARY })).result[:seen]

        home = seen.grep(/\AHOME=/).first.delete_prefix("HOME=")

        assert_equal File.join(cell.workspace, "0"), File.dirname(home)
        assert_match(/\Ahome-[0-9a-f]{16}\z/, File.basename(home))
      end
    end
  end

  def test_a_tool_gets_a_predictable_locale_so_its_output_does_not_shift_under_it
    with_canary do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment", payload: { canary: CANARY })).result[:seen]

        assert_includes seen, "LANG=C.UTF-8"
        assert_includes seen, "LC_ALL=C.UTF-8"
      end
    end
  end

  # An exec'd tool sees only what run_tool wrote for it, so the image's OpenMP bound has to be written
  # there too, or the shelled-out half of a toolchain — `magick`, `ffmpeg` — keeps an unbounded pool.
  def test_a_tool_inherits_the_cells_openmp_bound
    with_openmp_bound do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment")).result[:seen]

        assert_includes seen, "OMP_NUM_THREADS=2"
        assert_includes seen, "OMP_THREAD_LIMIT=8"
      end
    end
  end

  def test_a_tool_gets_no_openmp_bound_the_cell_does_not_have
    without_openmp_bound do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment")).result[:seen]

        assert_empty seen.grep(/\AOMP_/), "the cell invented a bound of its own"
      end
    end
  end

  # capture3 accumulated both streams in full and handed them over at exit, so slicing afterwards bounded
  # only the Strings this method returned. An input that made a tool print 40MB of diagnostics had
  # already cost this worker 40MB of address space — which RLIMIT_DATA charges, arriving as a `memory`
  # verdict for a document whose only crime was being noisy.
  def test_a_noisy_tool_costs_a_bounded_amount_of_the_workers_memory
    TestCell.boot do |cell|
      %w[ out err ].each do |stream|
        result = assert_ok(cell.call("test.noisy", payload: { stream: stream }, timeout: 30)).result

        assert_equal 1024, result[stream.to_sym], "#{stream} kept more than the capture"
        assert result[:ok], "the tool should have exited cleanly"
      end
    end
  end

  private
    def with_canary
      ENV[CANARY] = "must-not-leak"
      yield
    ensure
      ENV.delete CANARY
    end

    # The environment a container would have given the cell. A developer's own shell may hold either
    # variable, so both are restored rather than deleted.
    def with_openmp_bound(count = "2", limit = "8")
      original = ENV.slice("OMP_NUM_THREADS", "OMP_THREAD_LIMIT")
      ENV["OMP_NUM_THREADS"] = count
      ENV["OMP_THREAD_LIMIT"] = limit
      yield
    ensure
      ENV.delete "OMP_NUM_THREADS"
      ENV.delete "OMP_THREAD_LIMIT"
      ENV.update original
    end

    def without_openmp_bound(&block)
      with_openmp_bound(nil, nil, &block)
    end
end
