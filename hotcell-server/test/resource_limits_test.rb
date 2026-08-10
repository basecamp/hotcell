# frozen_string_literal: true

require "test_helper"

# Invariant 6 from the kernel's side. A clamp that silently stops clamping looks exactly like a clamp, so
# these assert the numbers the worker actually runs under rather than the numbers it was asked for.
class ResourceLimitsTest < HotCellServerTest
  CELL_MEMORY = 1200 * 1024**2
  CELL_FILE_SIZE = 8 * 1024 * 1024

  def test_a_worker_runs_under_the_cells_limits
    boot do |cell|
      limits = assert_ok(cell.call("test.rlimits")).result

      assert_equal [ CELL_MEMORY, CELL_MEMORY ], limits[:memory]
      assert_equal [ CELL_FILE_SIZE, CELL_FILE_SIZE ], limits[:file_size]
      assert_equal [ 256, 256 ], limits[:open_files]
    end
  end

  # The soft limit narrows to the operation and the hard limit stays at the cell's ceiling, which is what
  # lets a reused worker widen back for an operation with a different budget. Setting both would make the
  # first request the tightest the worker could ever be.
  def test_an_operation_narrows_the_soft_limit_and_leaves_the_hard_one_alone
    boot do |cell|
      limits = assert_ok(cell.call("test.frugal")).result

      assert_equal [ 1024 * 1024**2, CELL_MEMORY ], limits[:memory]
      assert_equal [ 4 * 1024 * 1024, CELL_FILE_SIZE ], limits[:file_size]
      assert_equal [ 64, 256 ], limits[:open_files]
    end
  end

  # Invariant 6 where the kernel enforces it. An operation cannot exceed its cell's limits whatever it
  # declares, and unclamped this does not merely get too much — it asks for a soft limit above its own hard
  # limit, which is EINVAL, and the worker dies before it can answer.
  def test_an_operation_asking_for_more_than_the_cell_allows_gets_the_cells_numbers
    boot do |cell|
      limits = assert_ok(cell.call("test.extravagant")).result

      assert_equal [ CELL_MEMORY, CELL_MEMORY ], limits[:memory]
      assert_equal [ CELL_FILE_SIZE, CELL_FILE_SIZE ], limits[:file_size]
      assert_equal [ 256, 256 ], limits[:open_files]
    end
  end

  # A reused worker meets a tight operation and then a generous one. The second must get its own budget
  # back, which only works because the hard limit was never lowered.
  def test_a_reused_worker_widens_back_for_the_next_operation
    boot(max_requests_per_worker: 2, concurrency: 1) do |cell|
      frugal = assert_ok(cell.call("test.frugal")).result
      roomy = assert_ok(cell.call("test.rlimits")).result

      assert_equal [ 64, 256 ], frugal[:open_files]
      assert_equal [ 256, 256 ], roomy[:open_files], "the worker could not widen back"
    end
  end

  def test_core_dumps_are_off
    boot { |cell| assert_equal [ 0, 0 ], assert_ok(cell.call("test.rlimits")).result[:core] }
  end

  # RLIMIT_FSIZE is enforced by a signal, so the worker cannot report its own death and the supervisor
  # answers for it. Without that the cold side would see a bare end of stream and could not tell a limit
  # breach from a crash.
  def test_writing_past_file_size_is_killed_rather_than_truncated
    boot do |cell|
      with_files do |source, destination|
        response = cell.call "test.overflowing", inputs: [ source ], outputs: [ destination ],
                                                 payload: { megabytes: 16 }, timeout: 30

        failure = assert_failed "killed", response, limit: "fsize"
        assert_predicate failure, :permanent?
        assert_equal "XFSZ", failure.signal
      end
    end
  end

  # One number covers the input copy as well as the output, deliberately: the kernel does not distinguish
  # them, so pretending the limit is only about outputs would just make it surprising.
  def test_file_size_bounds_the_input_copy_too
    boot do |cell|
      with_file("x" * (16 * 1024 * 1024)) do |source|
        with_file do |destination|
          response = cell.call "test.uppercase", inputs: [ source ], outputs: [ destination ], timeout: 30

          assert_failed "killed", response, limit: "fsize"
        end
      end
    end
  end

  # An allocation past RLIMIT_DATA is a catchable NoMemoryError rather than a signal, which makes it
  # tempting to report as an ordinary failure. It is the decompression-bomb case, so it belongs with the
  # other resource verdicts where a caller can act on it without parsing a message.
  def test_allocating_past_the_memory_limit_is_killed_rather_than_failed
    boot do |cell|
      failure = assert_failed "killed", cell.call("test.greedy", payload: { megabytes: 900 }, timeout: 30),
                              limit: "memory"

      assert_predicate failure, :permanent?
    end
  end

  def test_an_allocation_inside_the_limit_is_fine
    boot do |cell|
      assert_ok cell.call("test.greedy", payload: { megabytes: 64 }, timeout: 30)
    end
  end

  private
    def boot(**options, &block)
      TestCell.boot(memory: CELL_MEMORY, file_size: CELL_FILE_SIZE, **options, &block)
    end
end
