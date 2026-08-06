# frozen_string_literal: true

require "test_helper"

class CodesTest < HotCellTest
  # A caller cannot tell from `killed` alone whether a worker burned thirty seconds on a decompression
  # bomb or merely sat behind a queue past its deadline, and those demand opposite responses.
  def test_the_codes_that_mean_this_input_will_fail_again
    %w[ unreadable failed invalid ].each do |code|
      assert HotCell::Codes.terminal?(code), "expected #{code} to be terminal"
    end
  end

  def test_the_codes_that_mean_try_again
    %w[ protocol capacity unavailable timeout ].each do |code|
      refute HotCell::Codes.terminal?(code), "expected #{code} to be transient"
    end
  end

  # An accessory is not updated by a deploy, so an application that ships a client for a new operation before
  # anybody reboots the cell gets this at one hundred percent for as long as that takes. Recording it as
  # permanent condemns every blob uploaded during the window, and a caller's typo shows up in the rate and in
  # the client's boot-time warning instead.
  def test_an_operation_a_cell_does_not_carry_yet_is_a_deploy_window_rather_than_a_verdict
    refute HotCell::Codes.terminal?("unsupported")
  end

  def test_killed_answers_from_the_limit_the_worker_hit
    assert HotCell::Codes.terminal?("killed", limit: "fsize")
    assert HotCell::Codes.terminal?("killed", limit: "memory")
    assert HotCell::Codes.terminal?("killed", limit: "signal")
    refute HotCell::Codes.terminal?("killed", limit: "deadline")
  end

  def test_killed_with_no_limit_is_terminal
    assert HotCell::Codes.terminal?("killed")
  end

  def test_a_writer_asking_for_an_unknown_code_is_a_typo_rather_than_forward_compatibility
    assert_raises(ArgumentError) { HotCell::Codes.terminal?("nonsense") }
  end

  def test_known
    assert HotCell::Codes.known?("unreadable")
    assert HotCell::Codes.known?("killed")
    refute HotCell::Codes.known?("nonsense")
  end
end
