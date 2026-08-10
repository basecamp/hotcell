# frozen_string_literal: true

require "test_helper"

class OperationTest < RegistryIsolatedTest
  def test_the_name_defaults_to_the_underscored_class_name_with_namespaces_as_dots
    assert_equal "operation_test.transform_image", TransformImage.operation_name
  end

  def test_an_acronym_in_the_class_name
    assert_equal "operation_test.pdf_preview", PDFPreview.operation_name
  end

  # The cell-side convention is a trailing Operation — TransformImageOperation — and the client keeps the
  # bare name, so stripping the suffix is what lets both sides derive the same default.
  def test_the_default_name_strips_a_trailing_operation_suffix
    assert_equal "operation_test.extract_text", ExtractTextOperation.operation_name
  end

  def test_a_class_named_only_operation_keeps_its_name
    assert_equal "operation_test.operation", Operation.operation_name
  end

  def test_an_explicit_name_wins
    assert_equal "test.uppercase", Fixtures::Uppercase.operation_name
  end

  # A wire name is never used to derive a constant, so an anonymous class has nothing to derive from and
  # must say what it answers to.
  def test_an_anonymous_operation_needs_a_name
    anonymous = Class.new(HotCell::Operation)

    error = assert_raises(HotCell::ConfigurationError) { anonymous.operation_name }
    assert_match "needs an explicit", error.message
  end

  def test_limits_default_to_nothing_declared
    assert_empty TransformImage.limits.declared
  end

  def test_limits_are_inherited_by_a_subclass
    assert_equal 1, Fixtures::Impatient.limits.deadline
    assert_equal 300, Fixtures::Patient.limits.deadline
  end

  def test_callbacks_collect_rather_than_replace
    assert_equal [ :required, :also_required ], Callbacks.new.tap { Callbacks.before_fork.each(&:call) }.log
  end

  def test_a_superclasss_callbacks_run_first
    ran = []
    parent = Class.new(HotCell::Operation) do
      operation "operation_test.parent"
      before_fork { ran << :parent }
    end
    child = Class.new(parent) do
      operation "operation_test.child"
      before_fork { ran << :child }
    end

    child.before_fork.each(&:call)

    assert_equal [ :parent, :child ], ran
  end

  def test_unreadable_always_includes_the_frameworks_own_class
    assert_includes TransformImage.unreadable, HotCell::UnreadableInput
    assert_includes Fixtures::DeclaredUnreadable.unreadable, Fixtures::LibraryError
  end

  def test_an_operation_that_does_not_implement_perform_says_so
    assert_raises(NotImplementedError) { TransformImage.new.perform([], [], {}) }
  end

  class TransformImage < HotCell::Operation; end
  class ExtractTextOperation < HotCell::Operation; end
  class Operation < HotCell::Operation; end
  class PDFPreview < HotCell::Operation; end

  class Callbacks < HotCell::Operation
    def self.log
      @log ||= []
    end

    def log
      self.class.log
    end

    before_fork { log << :required }
    before_fork { log << :also_required }
  end
end
