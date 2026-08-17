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

  # A name that arrives on the wire is never used to derive a constant, so an anonymous class has nothing
  # to derive a routing name from and must say what it answers to.
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

  # An operator raising one number from an operations file must not lose the others. The declaration is
  # a set of values, and naming one changes one.
  def test_redeclaring_one_limit_keeps_the_others
    operation = Class.new(HotCell::Operation) do
      operation "operation_test.redeclared"
      limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256
    end

    operation.limits file_size: 128 * 1024**2

    assert_equal 128 * 1024**2, operation.limits.file_size
    assert_equal 30, operation.limits.deadline
    assert_equal 1280 * 1024**2, operation.limits.memory
    assert_equal 256, operation.limits.open_files
  end

  # A subclass narrowing one limit inherits the rest of its parent's declaration rather than starting
  # from nothing, for the same reason.
  def test_a_subclass_declaring_one_limit_inherits_the_rest
    parent = Class.new(HotCell::Operation) do
      operation "operation_test.roomy_parent"
      limits deadline: 60, file_size: 64 * 1024**2
    end
    child = Class.new(parent) do
      operation "operation_test.hurried_child"
      limits deadline: 5
    end

    assert_equal 5, child.limits.deadline
    assert_equal 64 * 1024**2, child.limits.file_size
    assert_equal 60, parent.limits.deadline, "declaring on the child changed the parent"
  end

  # Withdrawing goes through the declaration too, not only through Limits#merge, so a future filter that
  # dropped nils on the way in would fail here rather than silently making a limit un-withdrawable.
  def test_redeclaring_a_limit_to_nil_withdraws_it_and_keeps_the_others
    operation = Class.new(HotCell::Operation) do
      operation "operation_test.withdrawn"
      limits deadline: 30, file_size: 48 * 1024**2
    end

    operation.limits file_size: nil

    assert_nil operation.limits.file_size
    assert_equal 30, operation.limits.deadline
  end

  # A subclass copies its parent's values when it first declares, the way every other class-level
  # declaration here resolves: the first ancestor with a value wins, and once a class has its own it stops
  # looking up. So a parent redeclared later does not reach a child that has already declared. Pinned so
  # the choice is visible; live per-key inheritance would be a different design.
  def test_a_parents_later_redeclaration_does_not_reach_a_child_that_has_declared
    parent = Class.new(HotCell::Operation) do
      operation "operation_test.parent_redeclared"
      limits file_size: 48 * 1024**2
    end
    child = Class.new(parent) do
      operation "operation_test.child_snapshot"
      limits deadline: 5
    end

    parent.limits file_size: 16 * 1024**2

    assert_equal 48 * 1024**2, child.limits.file_size
    assert_equal 16 * 1024**2, parent.limits.file_size
  end

  # The other half of the snapshot rule: a subclass that has declared nothing of its own has nothing to
  # snapshot, so it keeps following its parent, including a redeclaration made after the subclass exists.
  def test_a_subclass_that_never_declares_follows_its_parent_live
    parent = Class.new(HotCell::Operation) do
      operation "operation_test.parent_live"
      limits file_size: 48 * 1024**2
    end
    child = Class.new(parent) { operation "operation_test.child_live" }

    parent.limits file_size: 16 * 1024**2

    assert_equal 16 * 1024**2, child.limits.file_size
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
    assert_raises(NotImplementedError) { TransformImage.new.perform([], []) }
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
