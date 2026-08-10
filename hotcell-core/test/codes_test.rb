# frozen_string_literal: true

require "test_helper"

class CodesTest < HotCellTest
  # Both of these are claims about the input, made by something that knew: an operation declaring what it
  # could not decode, or the protocol catching a caller breaking its own contract.
  def test_the_codes_that_mean_this_input_will_fail_again
    %w[ unreadable invalid ].each do |code|
      assert HotCell::Codes.permanent?(code), "expected #{code} to be permanent"
    end
  end

  def test_the_codes_that_mean_try_again
    %w[ protocol capacity unavailable timeout ].each do |code|
      refute HotCell::Codes.permanent?(code), "expected #{code} to be transient"
    end
  end

  # `failed` is whatever an unclassified exception became. Errno::ENOSPC is a StandardError, so a full tmpfs
  # or a full disk under the caller's output arrives here — and permanent meant those were written down
  # against a customer's file forever, for a condition that would have succeeded on retry.
  def test_an_unclassified_exception_is_not_a_verdict_on_the_input
    refute HotCell::Codes.permanent?("failed")
  end

  # An accessory is not updated by a deploy, so an application that ships a client for a new operation before
  # anybody reboots the cell gets this at one hundred percent for as long as that takes. Recording it as
  # permanent condemns every blob uploaded during the window, and a caller's typo shows up in the rate and in
  # the client's boot-time warning instead.
  def test_an_operation_a_cell_does_not_carry_yet_is_a_deploy_window_rather_than_a_verdict
    refute HotCell::Codes.permanent?("unsupported")
  end

  def test_killed_answers_from_the_limit_the_worker_hit
    assert HotCell::Codes.permanent?("killed", limit: "fsize")
    assert HotCell::Codes.permanent?("killed", limit: "memory")
    refute HotCell::Codes.permanent?("killed", limit: "deadline")
  end

  # A signal says how a process died, never why. The supervisor names its own deadline kill; anything else
  # arrived from a cgroup OOM chosen on aggregate pressure, or from a sibling worker sharing this uid.
  # Reading that as a verdict condemns an input for something it did not do.
  def test_an_unexplained_signal_is_not_a_verdict_on_the_input
    refute HotCell::Codes.permanent?("killed", limit: "signal")
  end

  # `killed` with no limit is the same ignorance as a limit the table does not carry: something killed the
  # worker and nothing says what. Every mint site in the cell sets a limit, so this is a malformed message or
  # a hand-written caller — and neither is grounds for condemning the input.
  def test_killed_with_no_limit_is_not_permanent
    refute HotCell::Codes.permanent?("killed")
  end

  def test_a_writer_asking_for_an_unknown_code_is_a_typo_rather_than_forward_compatibility
    assert_raises(ArgumentError) { HotCell::Codes.permanent?("nonsense") }
  end

  # The whole point of the table's default. A cell mints these, and a kill reason added to the supervisor
  # without a row here is a forgotten row rather than a verdict — so it must not come out permanent, which is
  # the answer that cannot be taken back.
  def test_a_limit_the_table_has_never_heard_of_is_not_permanent
    refute HotCell::Codes.permanent?("killed", limit: "oom")
    refute HotCell::Failure.new(code: "killed", limit: "oom").permanent?
  end

  # And it must not raise either, which is why this differs from an unknown code. Supervisor#answer_for builds
  # its Failure as an argument to `answer`, above that method's rescue, on the one path whose job is reporting
  # a dead worker — so a raise there would take the cell down instead of one request.
  def test_an_unknown_limit_does_not_raise
    HotCell::Codes.permanent? "killed", limit: "oom"
    HotCell::Failure.new code: "killed", limit: "oom"
  end

  # Every name the cell mints is a constant, so neither the supervisor nor the worker can spell one the table
  # does not carry.
  def test_every_named_limit_has_a_row
    [ HotCell::Codes::FSIZE, HotCell::Codes::MEMORY, HotCell::Codes::DEADLINE,
      HotCell::Codes::SIGNAL, HotCell::Codes::CRASHED ].each do |limit|
      assert HotCell::Codes::PERMANENT_BY_LIMIT.key?(limit), "#{limit} has no row"
    end
  end

  def test_known
    assert HotCell::Codes.known?("unreadable")
    assert HotCell::Codes.known?("killed")
    refute HotCell::Codes.known?("nonsense")
  end
end
