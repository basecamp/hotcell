# frozen_string_literal: true

require "test_helper"
require "hot_cell/install"
require "stringio"

class InstallTest < HotCellClientTest
  def test_install_writes_the_cell_scaffold
    Dir.mktmpdir do |root|
      out = StringIO.new
      HotCell::Install.call(root, out: out)

      dockerfile = File.read(File.join(root, "hotcell", "Dockerfile"))
      assert_match "FROM ruby", dockerfile
      assert_match "bundle install", dockerfile
      assert_match(/CMD \["bundle", "exec", "hotcell"\]/, dockerfile)

      gemfile = File.read(File.join(root, "hotcell", "Gemfile"))
      assert_match "hotcell-server", gemfile

      config = File.read(File.join(root, "hotcell", "config.rb"))
      assert_match "HotCell.limits", config

      assert File.exist?(File.join(root, "hotcell", "operations", ".keep")),
             "the operations directory must exist for the Dockerfile's COPY"
      assert_match "create  hotcell/Dockerfile", out.string
    end
  end

  def test_install_leaves_an_existing_file_exactly_as_it_is
    Dir.mktmpdir do |root|
      customized = File.join(root, "hotcell", "Dockerfile")
      FileUtils.mkdir_p File.dirname(customized)
      File.write customized, "# customized\n"

      out = StringIO.new
      HotCell::Install.call(root, out: out)

      assert_equal "# customized\n", File.read(customized)
      assert_match "skip  hotcell/Dockerfile", out.string
      assert File.exist?(File.join(root, "hotcell", "Gemfile")),
             "the other files should still be installed"
    end
  end
end
