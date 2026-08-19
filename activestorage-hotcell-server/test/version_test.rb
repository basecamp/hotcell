# frozen_string_literal: true

require "test_helper"

# The version file only, not the gem: test_helper explains why nothing here loads libvips.
require "active_storage/hot_cell/server/version"

class VersionTest < ActiveStorageHotCellTest
  # The gemspec builds from the repository's VERSION file and this constant is written from it, so the two
  # can drift. `rake version:bump` writes both.
  def test_this_gem_reports_the_version_its_gemspec_builds
    version = File.read(File.expand_path("../../VERSION", __dir__)).strip

    assert_equal version, ActiveStorage::HotCell::Server::VERSION, "run `rake version:bump` from the repository root"
  end
end
