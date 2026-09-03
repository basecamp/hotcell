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

  def test_boot_leaves_lost_and_found_alone
    FileUtils.mkdir File.join(@elsewhere, "lost+found")
    File.write File.join(@elsewhere, "lost+found", "#1234"), "recovered"
    File.chmod 0o500, File.join(@elsewhere, "lost+found")
    File.write File.join(@elsewhere, "magick-abc123"), "pixel cache"

    boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace")

    refute File.exist?(File.join(@elsewhere, "magick-abc123"))
    assert File.exist?(File.join(@elsewhere, "lost+found", "#1234"))
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

  def test_a_removal_that_fails_is_logged_and_boot_carries_on
    locked = File.join(@elsewhere, "locked")
    FileUtils.mkdir locked
    File.write File.join(locked, "inside"), "x"
    File.chmod 0o500, locked
    File.write File.join(@elsewhere, "magick-abc123"), "pixel cache"

    boot TestCell.new, workspace: File.join(@elsewhere, "hotcell-workspace") do |cell|
      assert_ok cell.call("test.echo")
      cell.stop

      uncleaned = cell.log_events("scratch.uncleaned")

      assert_equal 1, uncleaned.size
      assert_equal locked, uncleaned.first.dig(:hotcell, :path)
    end

    assert_equal [ "hotcell-workspace", "locked" ], Dir.children(@elsewhere).sort
  end

  def test_boot_leaves_the_socket_directory_when_it_lives_in_the_scratch
    cell = TestCell.new
    FileUtils.mkdir_p cell.tmpdir
    socket_directory = File.join(cell.tmpdir, "sockets")
    cell.instance_variable_set(:@directory, socket_directory)

    boot cell, workspace: cell.workspace do
      assert_ok cell.call("test.echo")
      assert File.socket?(File.join(socket_directory, "work.sock"))
    end
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
end
