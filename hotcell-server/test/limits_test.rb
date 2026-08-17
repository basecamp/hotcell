# frozen_string_literal: true

require "test_helper"

class LimitsTest < HotCellServerTest
  def test_a_declaration_below_the_memory_floor_is_refused_with_the_reason
    error = assert_raises HotCell::ConfigurationError do
      HotCell::Limits.new(memory: 512 * 1024**2)
    end

    assert_match "below the #{HotCell::Limits::MEMORY_FLOOR} byte floor", error.message
    assert_match "Ruby's own untouched reservation", error.message
  end

  def test_the_floor_itself_is_allowed
    assert_equal HotCell::Limits::MEMORY_FLOOR,
                 HotCell::Limits.new(memory: HotCell::Limits::MEMORY_FLOOR).memory
  end

  def test_a_non_positive_limit_is_refused
    assert_raises(HotCell::ConfigurationError) { HotCell::Limits.new(deadline: 0) }
    assert_raises(HotCell::ConfigurationError) { HotCell::Limits.new(file_size: -1) }
  end

  def test_nothing_declared_means_nothing_declared
    assert_empty HotCell::Limits.new.declared
  end

  # 30.seconds is an ActiveSupport::Duration, and the deadline travels as JSON in the worker's report —
  # so it must land here as a plain number, without this gem depending on activesupport.
  def test_an_active_support_duration_deadline_lands_as_plain_seconds
    require "active_support"
    require "active_support/core_ext/numeric"

    limits = HotCell::Limits.new(deadline: 30.seconds, memory: 1280.megabytes, file_size: 48.megabytes)

    assert_equal 30.0, limits.deadline
    assert_equal 1280 * 1024**2, limits.memory
    assert_equal 48 * 1024**2, limits.file_size
  end

  def test_merge_lays_named_values_over_the_rest
    merged = HotCell::Limits.new(deadline: 30, file_size: 100).merge(file_size: 200)

    assert_equal 200, merged.file_size
    assert_equal 30, merged.deadline
  end

  # Naming a limit to nil withdraws it, so a redeclaration can hand a limit back to the cell as well as
  # change it. Otherwise there would be no way to undeclare one short of rebuilding from scratch.
  def test_merge_withdraws_a_limit_named_to_nil
    merged = HotCell::Limits.new(deadline: 30, file_size: 100).merge(file_size: nil)

    assert_nil merged.file_size
    assert_equal 30, merged.deadline
  end

  # merge builds through the constructor, so it validates like a declaration does.
  def test_merge_refuses_a_memory_below_the_floor
    limits = HotCell::Limits.new(memory: HotCell::Limits::MEMORY_FLOOR)

    assert_raises(HotCell::ConfigurationError) { limits.merge(memory: HotCell::Limits::MEMORY_FLOOR - 1) }
  end

  def test_merge_does_not_change_the_original
    original = HotCell::Limits.new(deadline: 30)
    original.merge(deadline: 5)

    assert_equal 30, original.deadline
  end

  def test_clamping_takes_the_smaller_of_each
    operation = HotCell::Limits.new(deadline: 30, file_size: 100, open_files: 500)
    cell = HotCell::Limits.new(deadline: 60, file_size: 50, open_files: 256)

    clamped = operation.clamped_to(cell)

    assert_equal 30, clamped.deadline
    assert_equal 50, clamped.file_size
    assert_equal 256, clamped.open_files
  end

  def test_a_limit_an_operation_did_not_declare_comes_from_the_cell
    clamped = HotCell::Limits.new(deadline: 5).clamped_to(HotCell::Limits.new(deadline: 60, file_size: 99))

    assert_equal 5, clamped.deadline
    assert_equal 99, clamped.file_size
  end

  def test_a_limit_the_cell_did_not_declare_comes_from_the_operation
    assert_equal 5, HotCell::Limits.new(deadline: 5).clamped_to(HotCell::Limits.new).deadline
  end

  # The deadline is the supervisor's clock rather than an rlimit, which is the whole reason it can bound a
  # worker wedged on a subprocess that burns no CPU at all.
  def test_the_deadline_is_not_a_resource_limit
    refute_includes HotCell::Limits::RESOURCES.keys, :deadline
    assert_includes HotCell::Limits::KEYS, :deadline
  end

  # RLIMIT_AS is absent on purpose: it needs 34x headroom against real use where RLIMIT_DATA needs 15x, and
  # it fails nondeterministically for a 400MB band below its floor.
  def test_memory_is_rlimit_data_and_there_is_no_address_space_limit
    assert_equal Process::RLIMIT_DATA, HotCell::Limits::RESOURCES[:memory]
    refute_includes HotCell::Limits::RESOURCES.values, Process::RLIMIT_AS
  end
end
