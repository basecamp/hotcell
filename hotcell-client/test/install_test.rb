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

  # **`install_test` above runs from the checkout, where every template is present whether or not it was
  # packaged.** That is what let the published 0.1.0 advertise a scaffold it could not build: the gemspec
  # selects `Dir["lib/**/*"]`, which does not match a dotfile, so `install/operations/.keep.tt` was in the
  # working tree and not in the gem, and the generated Dockerfile's `COPY operations/` had nothing to copy.
  # This is the difference between the two lists.
  def test_every_installer_template_is_packaged
    root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(root, "hotcell-client.gemspec"))
    templates = Dir.glob("#{HotCell::Install::TEMPLATES}/**/*.tt", File::FNM_DOTMATCH)
      .map { |path| path.delete_prefix("#{root}/") }

    assert_empty templates - spec.files, "an installer template the published gem would not carry"
  end

  # The Gemfile template is ERB rather than a copy, because the cell's server and this client are halves of
  # one wire contract: a skew between them answers `protocol` on every request.
  def test_install_pins_the_cell_to_the_installing_clients_version
    Dir.mktmpdir do |root|
      HotCell::Install.call(root, out: StringIO.new)

      gemfile = File.read(File.join(root, "hotcell", "Gemfile"))

      assert_match %(gem "hotcell-server", "#{HotCell::Client::VERSION}"), gemfile
      refute_match "<%", gemfile
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
