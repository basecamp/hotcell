# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The supervisor moves a killed worker's scratch aside with an O(1) rename rather than deleting it, because
# the size of the tree is chosen by the input. A rename that fails must not fall back to a recursive delete
# in the supervisor — that is the unbounded work the rename exists to avoid, and an exploited tool can
# induce it.
class SlotTest < HotCellServerTest
  def setup
    @workspace = Dir.mktmpdir "hotcell-slot-test"
    @slot = HotCell::Slot.build(@workspace, 0)
  end

  def teardown
    FileUtils.remove_entry @workspace if Dir.exist?(@workspace)
  end

  def test_a_rename_failure_leaves_the_tree_rather_than_deleting_it_inline
    @slot.make_scratch
    marker = File.join(@slot.scratch, "one-of-a-million-files")
    File.write marker, "stands in for an attacker-sized tree"

    stub_rename_to_fail do
      @slot.discard_scratch
    end

    assert File.exist?(marker), "the supervisor deleted the scratch tree inline instead of leaving it"
  end

  def test_a_discard_renames_the_tree_aside_for_a_later_sweep
    @slot.make_scratch
    File.write File.join(@slot.scratch, "leftover"), "x"

    @slot.discard_scratch

    refute Dir.exist?(@slot.scratch), "scratch should have been renamed away"
    assert_equal 1, discarded_names.size, "the tree should be waiting under a discarded name"

    @slot.sweep
    assert_empty discarded_names, "sweep should remove the discarded tree"
  end

  def test_the_discarded_name_carries_an_unpredictable_suffix
    @slot.make_scratch
    @slot.discard_scratch

    name = discarded_names.first

    assert_match(/\.discarded-#{Process.pid}-[0-9a-f]{16}\z/, name,
                 "the discarded name should end in a random suffix a tool cannot pre-create")
  end

  private
    def discarded_names
      Dir.glob("#{@slot.scratch}.discarded-*").map { |path| File.basename(path) }
    end

    def stub_rename_to_fail
      original = File.method(:rename)
      File.define_singleton_method(:rename) { |*| raise Errno::ENOTEMPTY, "induced" }
      yield
    ensure
      File.define_singleton_method(:rename, original)
    end
end
