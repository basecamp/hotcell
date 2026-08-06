# frozen_string_literal: true

require "test_helper"

# Invariant 9, and the one thing about a cell's environment that is actually under our control.
#
# A worker is forked, so its own /proc/self/environ is the exec-time environment of the process it came from,
# and ENV.delete changes nothing a sibling worker can read. An exec'd child is different: it gets a fresh
# environ, and that is the only point where we choose what a converter sees.
#
# `unsetenv_others: true` is one keyword whose removal changes nothing observable in normal operation, which
# is exactly why it is tested.
class EnvironmentTest < HotCellServerTest
  CANARY = "HOTCELL_ENVIRONMENT_TEST_CANARY"

  def test_a_converter_sees_only_what_its_operation_wrote_for_it
    with_canary do
      TestCell.boot do |cell|
        result = assert_ok(cell.call("test.environment",
                                     payload: { canary: CANARY, env: { "CONVERTER_SETTING" => "yes" } })).result

        # The premise first: the worker really did inherit the canary, so its absence below means something.
        assert_equal "must-not-leak", result[:worker_saw]

        assert_includes result[:seen], "CONVERTER_SETTING=yes"
        assert_empty result[:seen].grep(/#{CANARY}/),
                     "the converter inherited the worker's environment"
      end
    end
  end

  def test_a_converter_gets_the_slots_home_rather_than_the_callers
    with_canary do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment", payload: { canary: CANARY })).result[:seen]

        assert_includes seen, "HOME=#{File.join(cell.workspace, "0", "home")}"
      end
    end
  end

  def test_a_converter_gets_a_predictable_locale_so_its_output_does_not_shift_under_it
    with_canary do
      TestCell.boot do |cell|
        seen = assert_ok(cell.call("test.environment", payload: { canary: CANARY })).result[:seen]

        assert_includes seen, "LANG=C.UTF-8"
        assert_includes seen, "LC_ALL=C.UTF-8"
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
end
