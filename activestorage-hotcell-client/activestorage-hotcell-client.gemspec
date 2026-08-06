# frozen_string_literal: true

require_relative "lib/active_storage/hot_cell/client/version"

Gem::Specification.new do |spec|
  spec.name        = "activestorage-hotcell-client"
  spec.version     = ActiveStorage::HotCell::CLIENT_VERSION
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/activestorage-hotcell"
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
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]

  spec.add_dependency "hotcell-client", ">= 0.1.0"
  spec.add_dependency "activestorage", ">= 8.1"
end
