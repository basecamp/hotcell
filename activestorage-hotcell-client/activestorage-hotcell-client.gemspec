# frozen_string_literal: true

version = File.read(File.expand_path("../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name        = "activestorage-hotcell-client"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "Point Active Storage's transformer, analyzer, and previewers at a HotCell."
  spec.description = <<~TEXT
    The three classes an application configures Rails with, so that variants, image analysis, and previews
    happen in an unprivileged container instead of in the application process.

    It also closes what Rails leaves open on that path: the built-in analyzers go silent when
    variant_processor is a class, the built-in previewers answer accept? by shelling out to look for a
    binary that is no longer there, and none of the jobs retries anything a cell can transiently answer.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]

  spec.add_dependency "hotcell-client", version

  # 8.2 is where config.active_storage.variant_processor began accepting a class (rails/rails#58384), and
  # without it a transformer class fails at the first variant rather than at boot. Spelled as the
  # prerelease because that is what rails/rails main reports and 8.2 is unreleased: ">= 8.2" sorts after
  # every 8.2 prerelease and would reject it.
  spec.add_dependency "activestorage", ">= 8.2.0.alpha"
end
