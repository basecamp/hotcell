# frozen_string_literal: true

require "test_helper"

# The scratch outlives the container: on the reference accessory it is a host mount, so a file a killed tool
# left at its top survives every restart. Boot is what empties it, and only of what the cell's own uid owns.
# Inside a TestCell `Dir.tmpdir` is the cell's own `tmpdir`, so these seed there and in a workspace parent
# of their own.
class ScratchTest < RegistryIsolatedTest
  def setup
    super
    @elsewhere = Dir.mktmpdir "hotcell-scratch"
  end

  def teardown
    Dir.glob(File.join(@elsewhere, "**/"), File::FNM_DOTMATCH).each { |path| File.chmod 0o700, path }
    FileUtils.remove_entry @elsewhere
    super
  end

  def test_boot_empties_tmpdir_and_the_workspaces_parent_of_what_earlier_workers_left
    cell = TestCell.new
    FileUtils.mkdir_p cell.tmpdir
    File.write File.join(cell.tmpdir, "magick-abc123"), "pixel cache"
    FileUtils.mkdir_p File.join(@elsewhere, "vips-0-xyz", "deeper")
    File.write File.join(@elsewhere, "vips-0-xyz", "deeper", "tile"), "x"

    boot cell, workspace: File.join(@elsewhere, "hotcell-workspace") do
      assert_ok cell.call("test.echo")
    end

    refute File.exist?(File.join(cell.tmpdir, "magick-abc123"))
    assert_equal [ "hotcell-workspace" ], Dir.children(@elsewhere)
  end

  # The real lost+found is the filesystem's and root's, so ownership is what spares it. A directory of that
  # name this uid owns is a worker's, and a name that was spared was a name a worker could fill.
  def test_boot_removes_a_lost_and_found_the_cell_owns
    FileUtils.mkdir File.join(@elsewhere, "lost+found")
    File.write File.join(@elsewhere, "lost+found", "magick-abc123"), "pixel cache"

    boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace")

    refute Dir.exist?(File.join(@elsewhere, "lost+found"))
  end

  def test_boot_unlinks_a_symlink_without_following_it
    Dir.mktmpdir "hotcell-target" do |target|
      File.write File.join(target, "keep"), "not the cell's"
      File.symlink target, File.join(@elsewhere, "escape")

      boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace")

      refute File.symlink?(File.join(@elsewhere, "escape"))
      assert File.exist?(File.join(target, "keep")), "the boot followed a symlink out of the scratch"
    end
  end

  def test_boot_puts_back_the_modes_a_tool_changed_and_removes_the_tree
    locked = File.join(@elsewhere, "locked")
    FileUtils.mkdir_p File.join(locked, "inside")
    File.write File.join(locked, "inside", "tile"), "x"
    File.chmod 0o500, File.join(locked, "inside")
    File.chmod 0o500, locked

    boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace")

    refute Dir.exist?(locked)
  end

  def test_boot_puts_back_the_mode_of_a_scratch_root_it_cannot_list
    File.write File.join(@elsewhere, "magick-abc123"), "pixel cache"
    File.chmod 0o300, @elsewhere

    boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace")

    refute File.exist?(File.join(@elsewhere, "magick-abc123"))
  end

  def test_a_removal_that_still_fails_is_logged_and_boot_carries_on
    File.write File.join(@elsewhere, "magick-abc123"), "pixel cache"

    cell = TestCell.new
    cell.instance_variable_get(:@supervisor_options)[:workspace] = File.join(@elsewhere, "hotcell-workspace")
    stub_remove_entry_to_fail { cell.start }

    assert_ok cell.call("test.echo")
    cell.stop
    unswept = cell.log_events("scratch.unswept")

    assert_equal [ File.join(@elsewhere, "magick-abc123") ], unswept.map { |event| event.dig(:hotcell, :path) }
    assert_equal [ "WARN" ], unswept.map { |event| event.dig(:log, :level) }
  ensure
    cell&.stop
    cell&.cleanup
  end

  def test_a_socket_directory_inside_the_scratch_refuses_to_boot
    cell = TestCell.new
    FileUtils.mkdir_p cell.tmpdir
    cell.instance_variable_set(:@directory, File.join(cell.tmpdir, "sockets"))

    error = assert_raises(RuntimeError) { boot cell, workspace: cell.workspace }

    assert_match "is inside the scratch", error.message
  end

  def test_a_scratch_root_that_is_a_symlink_refuses_to_boot
    Dir.mktmpdir "hotcell-target" do |target|
      File.symlink target, File.join(@elsewhere, "link")

      error = assert_raises(RuntimeError) do
        boot TestCell.new, workspace: File.join(@elsewhere, "link", "hotcell-workspace")
      end

      assert_match "is a symlink", error.message
      assert_empty Dir.children(target)
    end
  end

  def test_a_relative_workspace_refuses_to_boot
    error = assert_raises(RuntimeError) { boot TestCell.new, workspace: "hotcell-workspace" }

    assert_match "is not an absolute path", error.message
  end

  private
    def boot(cell, workspace:)
      cell.instance_variable_get(:@supervisor_options)[:workspace] = workspace
      cell.start
      yield cell if block_given?
    ensure
      cell.stop
      cell.cleanup
    end

    # The cell forks from this process, so a stub installed here is inherited by the supervisor.
    def stub_remove_entry_to_fail
      original = FileUtils.method(:remove_entry)
      FileUtils.define_singleton_method(:remove_entry) { |*| raise Errno::ENOTEMPTY, "induced" }
      yield
    ensure
      FileUtils.define_singleton_method(:remove_entry, original)
    end
end
