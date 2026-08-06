# frozen_string_literal: true

require "test_helper"

class RegistryTest < RegistryIsolatedTest
  def test_an_operation_registers_itself_by_existing
    registered = Class.new(HotCell::Operation) { operation "registry_test.thing" }

    assert_includes HotCell::Registry.operations, registered
    assert_equal registered, HotCell::Registry.lookup("registry_test.thing")
  end

  def test_an_unknown_name_resolves_to_nothing_rather_than_to_a_constant
    assert_nil HotCell::Registry.lookup("registry_test.nothing")
    assert_nil HotCell::Registry.lookup("Kernel")
    assert_nil HotCell::Registry.lookup("HotCell::Registry")
  end

  def test_renaming_an_operation_is_visible_immediately
    thing = Class.new(HotCell::Operation) { operation "registry_test.before" }
    thing.operation "registry_test.after"

    assert_nil HotCell::Registry.lookup("registry_test.before")
    assert_equal thing, HotCell::Registry.lookup("registry_test.after")
  end

  def test_two_operations_claiming_one_name_is_a_boot_time_error
    Class.new(HotCell::Operation) { operation "registry_test.contested" }
    Class.new(HotCell::Operation) { operation "registry_test.contested" }

    error = assert_raises(HotCell::ConfigurationError) { HotCell::Registry.names }
    assert_match "both answer to \"registry_test.contested\"", error.message
  end

  def test_the_consist_is_reportable_in_a_stable_order
    names = HotCell::Registry.names

    assert_includes names, "test.uppercase"
    assert_equal names.sort, names
  end

  def test_clearing_leaves_nothing_behind
    HotCell::Registry.clear

    assert_empty HotCell::Registry.operations
    assert_nil HotCell::Registry.lookup("test.uppercase")
  end
end
