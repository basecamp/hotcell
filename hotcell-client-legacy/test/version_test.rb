# frozen_string_literal: true

require "test_helper"

class VersionTest < LegacyTest
  # The gemspec builds from the repository's VERSION file and this constant is written from it, so the two
  # can drift. `rake version:bump` writes both.
  def test_this_gem_reports_the_version_its_gemspec_builds
    version = File.read(File.expand_path("../../../VERSION", __FILE__)).strip

    assert_equal version, HotCell::Client::Legacy::VERSION, "run `rake version:bump` from the repository root"
  end
end
