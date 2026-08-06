# frozen_string_literal: true

require "test_helper"

class RegistrationTest < HotCellClientTest
  def test_both_socket_paths_come_from_one_directory
    HotCell.root = "/run/hotcell"
    cell = HotCell.register "active_storage"

    assert_equal "/run/hotcell/active_storage/work.sock", cell.work_socket
    assert_equal "/run/hotcell/active_storage/control.sock", cell.control_socket
  end

  def test_an_explicit_directory_wins
    HotCell.root = "/run/hotcell"
    cell = HotCell.register "archiver", dir: "/tmp/dev/archiver"

    assert_equal "/tmp/dev/archiver/work.sock", cell.work_socket
  end

  # Read at call time, not at registration. A directory consulted once at boot would make turning a path on
  # a deploy, and reverting one too.
  def test_a_callable_directory_is_resolved_on_every_call
    directory = nil
    cell = HotCell.register "archiver", dir: -> { directory }

    refute_predicate cell, :enabled?

    directory = "/tmp/dev/archiver"
    assert_predicate cell, :enabled?
    assert_equal "/tmp/dev/archiver/work.sock", cell.work_socket
  end

  # Unset means run in process exactly as today, which is the off position of the whole rollout.
  def test_no_root_and_no_directory_means_this_path_is_off
    cell = HotCell.register "active_storage"

    refute_predicate cell, :enabled?
    assert_nil cell.directory
  end

  def test_naming_a_cell_nobody_registered
    error = assert_raises(HotCell::UnregisteredCell) { HotCell.cell("nothing_like_it") }

    assert_match "no cell named \"nothing_like_it\"", error.message
  end

  # The inheritance graph is the classification, so a later tidying pass that gives both a common ancestor
  # silently turns every retryable failure into a permanent one. This refuses it at registration rather than
  # waiting for the first cell restart to discover it.
  def test_a_transient_class_descending_from_the_permanent_one_is_refused
    permanent = Class.new(StandardError)
    transient = Class.new(permanent)

    error = assert_raises HotCell::ConfigurationError do
      HotCell.register "active_storage", permanent: permanent, transient: transient
    end

    assert_match "would be recorded as a permanent one", error.message
  end

  def test_the_two_defaults_are_not_related
    refute HotCell::TransientFailure <= HotCell::PermanentFailure
    refute HotCell::PermanentFailure <= HotCell::TransientFailure
  end

  def test_terminal_chooses_the_permanent_class_and_anything_else_the_transient_one
    cell = HotCell.register "active_storage", permanent: Unprocessable, transient: TemporarilyUnavailable

    assert_equal Unprocessable, cell.exception_for(HotCell::Failure.new(code: "unreadable"))
    assert_equal TemporarilyUnavailable, cell.exception_for(HotCell::Failure.new(code: "capacity"))
    assert_equal TemporarilyUnavailable,
                 cell.exception_for(HotCell::Failure.new(code: "killed", limit: "deadline"))
    assert_equal Unprocessable, cell.exception_for(HotCell::Failure.new(code: "killed", limit: "memory"))
  end
end
