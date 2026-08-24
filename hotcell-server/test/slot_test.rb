# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The supervisor moves a killed worker's directory aside with an O(1) rename rather than deleting it,
# because the size of the tree is chosen by the input. A rename that fails must not fall back to a recursive
# delete in the supervisor — that is the unbounded work the rename exists to avoid, and an exploited tool
# can induce it.
class SlotTest < HotCellServerTest
  def setup
    @workspace = Dir.mktmpdir "hotcell-slot-test"
    @slot = HotCell::Slot.build(@workspace, 0)
  end

  def teardown
    restore_modes
    FileUtils.remove_entry @workspace if Dir.exist?(@workspace)
  end

  # adr/0003 says no file outlives its request, and `max_requests_per_worker: 1` is priced on that. A tool
  # that reaches code execution runs as the user that owns the tree, so it can make its own configuration
  # undeletable and lock the directory the next home would be created in. If the next request lands on the
  # same path it reads that configuration, and ImageMagick's `delegates.xml` is a command line.
  def test_a_home_a_tool_locked_open_is_never_handed_to_a_later_request
    first = @slot.make_home
    delegates = File.join(first, ".config", "ImageMagick", "delegates.xml")
    FileUtils.mkdir_p File.dirname(delegates)
    File.write delegates, "<delegatemap/>"
    File.chmod 0o500, File.dirname(delegates)
    File.chmod 0o500, @slot.directory

    @slot.remove_home
    second = @slot.make_home

    refute_equal first, second, "the next request was handed the path the last one poisoned"
    refute File.exist?(File.join(second, ".config", "ImageMagick", "delegates.xml")),
           "the next request read configuration the last one wrote"
  end

  # The name is the guarantee and the removal is what keeps the disk. A mode is the only thing a tool needs
  # to make its own tree unremovable, and a mode on a tree this uid owns is ours to put back — so a failed
  # removal is retried after repairing what the tool changed, rather than left to accumulate one tree per
  # request until the tmpfs is full.
  def test_a_tree_a_tool_made_unremovable_is_repaired_and_removed
    home = @slot.make_home
    locked = File.join(home, ".config")
    FileUtils.mkdir_p locked
    File.write File.join(locked, "delegates.xml"), "<delegatemap/>"
    File.chmod 0o500, locked

    assert @slot.remove_home, "the removal gave up on a mode it could have repaired"
    refute Dir.exist?(home), "the tree is still on the tmpfs"
  end

  def test_a_discarded_tree_a_tool_made_unremovable_is_repaired_and_swept
    home = @slot.make_home
    locked = File.join(home, ".config")
    FileUtils.mkdir_p locked
    File.write File.join(locked, "delegates.xml"), "<delegatemap/>"
    File.chmod 0o500, locked

    assert @slot.discard_home
    assert @slot.sweep, "the sweep gave up on a mode it could have repaired"
    assert_empty discarded_names, "the discarded tree is still on the tmpfs"
  end

  # A home whose cleanup genuinely could not run is still never reused, because the name of the next one is
  # not a name any earlier request has held.
  def test_a_home_whose_cleanup_failed_is_never_handed_to_a_later_request
    first = @slot.make_home
    File.write File.join(first, "delegates.xml"), "<delegatemap/>"

    stub_remove_entry_to_fail do
      refute @slot.remove_home, "a removal that failed reported success"
    end

    second = @slot.make_home

    refute_equal first, second
    refute File.exist?(File.join(second, "delegates.xml"))
  end

  # `Dir.exist?` follows symlinks and answers false for a dangling one, so an entry a tool left in the slot's
  # place survived the boot sweep and every later `make_home` raised on it.
  def test_a_slot_directory_that_is_not_a_directory_is_cleared_at_boot
    File.symlink File.join(@workspace, "nowhere"), @slot.directory

    assert @slot.prepare, "the boot sweep reported success without clearing the entry"
    refute File.symlink?(@slot.directory), "the entry a tool left in the slot's place is still there"

    @slot.make_home
  end

  def test_a_rename_failure_leaves_the_tree_rather_than_deleting_it_inline
    @slot.make_home
    marker = File.join(@slot.home, "one-of-a-million-files")
    File.write marker, "stands in for an attacker-sized tree"

    stub_rename_to_fail do
      @slot.discard_home
    end

    assert File.exist?(marker), "the supervisor deleted the scratch tree inline instead of leaving it"
  end

  def test_a_discard_renames_the_tree_aside_for_a_later_sweep
    home = @slot.make_home
    File.write File.join(home, "leftover"), "x"

    @slot.discard_home

    refute Dir.exist?(home), "the directory should have been renamed away"
    assert_equal 1, discarded_names.size, "the tree should be waiting under a discarded name"

    @slot.sweep
    assert_empty discarded_names, "sweep should remove the discarded tree"
  end

  def test_the_discarded_name_carries_an_unpredictable_suffix
    @slot.make_home
    @slot.discard_home

    name = discarded_names.first

    assert_match(/\Adiscarded-#{Process.pid}-[0-9a-f]{16}\z/, name,
                 "the discarded name should end in a random suffix a tool cannot pre-create")
  end

  # Every cleanup here runs where a raise is not survivable: the worker's ensure, and the supervisor's own
  # loop. So they answer rather than raise, and the callers log a false. Reporting a failure as success is
  # what made a request's staged bytes outlive the answer with nothing said — and a sibling worker can cause
  # one, by writing into the tree while remove_entry walks it.
  def test_a_cleanup_that_could_not_run_answers_false
    @slot.make_home

    stub_remove_entry_to_fail do
      refute @slot.remove_home, "a removal that failed reported success"
      refute @slot.prepare, "prepare reported success while the home was still there"
    end

    stub_rename_to_fail do
      refute @slot.discard_home, "a rename that failed reported success"
    end
  end

  def test_a_cleanup_that_ran_answers_true
    @slot.make_home

    assert @slot.discard_home
    assert @slot.sweep
    assert @slot.remove_home, "a home that is already gone is the outcome this wants"
    assert @slot.prepare
  end

  private
    def restore_modes
      Dir.glob(File.join(@workspace, "**/"), File::FNM_DOTMATCH).each do |path|
        File.chmod 0o700, path
      rescue SystemCallError
        nil
      end
    end

    def discarded_names
      Dir.glob(File.join(@slot.directory, "discarded-*")).map { |path| File.basename(path) }
    end

    def stub_remove_entry_to_fail
      original = FileUtils.method(:remove_entry)
      FileUtils.define_singleton_method(:remove_entry) { |*| raise Errno::ENOTEMPTY, "induced" }
      yield
    ensure
      FileUtils.define_singleton_method(:remove_entry, original)
    end

    def stub_rename_to_fail
      original = File.method(:rename)
      File.define_singleton_method(:rename) { |*| raise Errno::ENOTEMPTY, "induced" }
      yield
    ensure
      File.define_singleton_method(:rename, original)
    end
end
