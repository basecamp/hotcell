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

  # `restricted_env=` arrived in mini_magick 5.2.0 — 5.1.2 and 4.13.2 lack it — and magick_operation.rb calls
  # it at require time.
  def test_mini_magick_floor_provides_restricted_env
    assert_effective_floor "mini_magick", "5.2.0"
  end

  # `Vips.block_untrusted` arrived in ruby-vips 2.2.1 — 2.2.0 lacks it — and vips_operation.rb's before_fork
  # guard refuses to boot without it.
  def test_ruby_vips_floor_provides_block_untrusted
    assert_effective_floor "ruby-vips", "2.2.1"
  end

  private
    def requirement_for(gem_name)
      dependency = GEMSPEC.dependencies.find { |candidate| candidate.name == gem_name }
      assert dependency, "#{gem_name} is not a declared dependency of the gemspec"
      dependency.requirement
    end

    # The declared requirement's effective lower bound must be at least `floor`, whatever form the requirement
    # takes — asserting the bound structurally rather than probing point versions, so neither a later
    # `>= 4.0, != 5.1.2` nor a `>= 5.2.0.rc1` can slip a release lacking the API back in below it. An upper
    # bound (`< 6`) is fine; only the lower-bound clauses decide the floor, and their tightest is the smallest
    # version the requirement admits.
    LOWER_BOUND_OPERATORS = %w[ >= > = ~> ].freeze

    def assert_effective_floor(gem_name, floor)
      lower_bounds = requirement_for(gem_name).requirements
        .select { |operator, _version| LOWER_BOUND_OPERATORS.include?(operator) }
        .map { |_operator, version| version }

      assert_predicate lower_bounds, :any?, "#{gem_name} declares no lower bound; it must floor at #{floor}"
      assert_operator lower_bounds.max, :>=, Gem::Version.new(floor),
                      "#{gem_name} floor must be at least #{floor}, the version that introduced the API the " \
                      "operations call at boot"
    end
end
