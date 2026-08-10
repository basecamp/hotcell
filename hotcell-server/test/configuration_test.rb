# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < RegistryIsolatedTest
  def test_a_cell_boots_with_defaults
    configuration = HotCell::Configuration.new

    assert_equal 4, configuration.concurrency
    assert_equal 1, configuration.max_requests_per_worker
    assert_equal 60, configuration.limits.deadline
  end

  def test_scheduling_and_limits_are_declared_in_one_call
    configuration = HotCell::Configuration.new(concurrency: 2, deadline: 30, file_size: 1024)

    assert_equal 2, configuration.concurrency
    assert_equal 30, configuration.limits.deadline
    assert_equal 1024, configuration.limits.file_size
  end

  def test_an_unknown_setting_is_refused_rather_than_ignored
    error = assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(concurency: 2) }

    assert_match "unknown setting concurency", error.message
  end

  def test_the_queue_is_configured_directly
    assert_equal 8, HotCell::Configuration.new(concurrency: 4).queue_size
    assert_equal 0, HotCell::Configuration.new(concurrency: 4, queue_size: 0).queue_size
  end

  def test_reuse_counts_requests_before_a_worker_is_discarded
    configuration = HotCell::Configuration.new(max_requests_per_worker: 3)

    refute configuration.retire?(2)
    assert configuration.retire?(3)
    assert configuration.retire?(4)
  end

  # Intended for cells whose operations are all subprocess ones: persistent workers there give up nothing,
  # keep their slot's tool profile warm, and never pay the settling cost at all.
  def test_unlimited_reuse_never_retires
    configuration = HotCell::Configuration.new(max_requests_per_worker: :unlimited)

    assert_predicate configuration, :unlimited_requests?
    refute configuration.retire?(10_000)
  end

  def test_nonsense_scheduling_is_refused
    assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(concurrency: 0) }
    assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(queue_size: -1) }
    assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(queue_wait: 0) }
    assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(max_requests_per_worker: 0) }
    assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(max_requests_per_worker: :forever) }
  end

  def test_it_reports_the_longest_it_may_take_to_answer
    configuration = HotCell::Configuration.new(queue_wait: 10, deadline: 60)

    assert_equal 71, configuration.answer_within
    assert_equal 71, configuration.to_h[:answer_within]
  end
end
