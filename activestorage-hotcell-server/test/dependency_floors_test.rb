# frozen_string_literal: true

require "test_helper"

# The gemspec declares the versions an installer is allowed to resolve, and the operations call methods only
# some of those versions carry. magick_operation.rb sets `MiniMagick.restricted_env=`, added in mini_magick
# 5.2.0; vips_operation.rb's before_fork guard requires `Vips.block_untrusted`, added in ruby-vips 2.2.1. A
# floor below either lets an installer satisfy this gemspec and then die at boot — `NoMethodError` on the
# magick side, a fail-closed `ConfigurationError` on the vips side — with the whole conversion toolchain
# offline.
#
# This is the fast, syntactic half of the guard: it reads the declared requirement rather than resolving and
# booting against it, so it runs in every suite with nothing installed. The `activestorage-minimum` CI lane is
# the behavioural half — it installs these floors and runs the real conversions, so a converter method adopted
# from a still-newer version is caught even before the constants below are updated to name it.
class DependencyFloorsTest < ActiveStorageHotCellTest
  GEMSPEC = Gem::Specification.load File.expand_path("../activestorage-hotcell-server.gemspec", __dir__)

  # 5.1.2 and 4.13.2 lack `restricted_env=`; magick_operation.rb calls it at require time.
  def test_mini_magick_floor_provides_restricted_env
    assert_floor_excludes "mini_magick", "5.1.2"
    assert_floor_admits   "mini_magick", "5.2.0"
  end

  # 2.2.0 lacks `Vips.block_untrusted`; vips_operation.rb's before_fork guard refuses to boot without it.
  def test_ruby_vips_floor_provides_block_untrusted
    assert_floor_excludes "ruby-vips", "2.2.0"
    assert_floor_admits   "ruby-vips", "2.2.1"
  end

  private
    def requirement_for(gem_name)
      dependency = GEMSPEC.dependencies.find { |candidate| candidate.name == gem_name }
      assert dependency, "#{gem_name} is not a declared dependency of the gemspec"
      dependency.requirement
    end

    def assert_floor_excludes(gem_name, version)
      refute requirement_for(gem_name).satisfied_by?(Gem::Version.new(version)),
             "#{gem_name} floor must exclude #{version}, which lacks the API the operations call at boot"
    end

    def assert_floor_admits(gem_name, version)
      assert requirement_for(gem_name).satisfied_by?(Gem::Version.new(version)),
             "#{gem_name} floor must admit #{version}, the version that introduced the API"
    end
end
