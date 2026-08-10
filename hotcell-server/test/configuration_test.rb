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
  # keep their slot's converter profile warm, and never pay the settling cost at all.
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

  # The trade is supported and often right. What must not happen is that somebody makes it silently by
  # adding an operation to an existing cell.
  def test_reuse_above_one_warns_and_names_the_operations_that_parse_in_process
    warning = HotCell::Configuration.new(max_requests_per_worker: 3).in_process_warning([ Fixtures::Uppercase ])

    assert_match "max_requests_per_worker: 3", warning
    assert_match "test.uppercase", warning
    assert_match "up to 2 later request", warning
  end

  def test_reuse_of_one_has_nothing_to_warn_about
    assert_nil HotCell::Configuration.new(max_requests_per_worker: 1).in_process_warning([ Fixtures::Uppercase ])
  end

  def test_a_cell_of_subprocess_operations_has_nothing_to_warn_about
    subprocess = Class.new(HotCell::Operation) do
      operation "test.subprocess_only"
      untrusted_input :subprocess
    end

    assert_nil HotCell::Configuration.new(max_requests_per_worker: 5).in_process_warning([ subprocess ])
  end

  # This goes on the wire as the answer to hotcell.describe, so "reportable" has to mean serializable and not
  # just present. :unlimited is the one supported value that is not JSON-native, and a cell configured with it
  # could not describe itself at all.
  def test_the_whole_configuration_is_reportable
    reported = HotCell::Configuration.new(concurrency: 2, deadline: 30).to_h

    assert_equal 2, reported[:concurrency]
    assert_equal 30, reported[:deadline]
    assert_equal reported, HotCell::Payload.validate!(reported, "result")
  end

  def test_unlimited_reuse_is_reportable_too
    reported = HotCell::Configuration.new(max_requests_per_worker: :unlimited).to_h

    assert_equal "unlimited", reported[:max_requests_per_worker]
    assert_equal reported, HotCell::Payload.validate!(reported, "result")
  end

  # A nil is a missing number rather than "use the default". A cell whose deadline is nil accepts every
  # request and then dies on the first arithmetic the supervisor does with it.
  def test_a_limit_explicitly_set_to_nil_is_refused_where_it_is_written
    error = assert_raises(HotCell::ConfigurationError) { HotCell::Configuration.new(deadline: nil) }

    assert_match "deadline cannot be nil", error.message
  end

  # The client compares its own timeout against this rather than adding up the parts, so the cell is the one
  # side that has to know what its stages cost.
  def test_it_reports_the_longest_it_may_take_to_answer
    configuration = HotCell::Configuration.new(queue_wait: 10, deadline: 60)

    assert_equal 71, configuration.answer_within
    assert_equal 71, configuration.to_h[:answer_within]
  end
end
