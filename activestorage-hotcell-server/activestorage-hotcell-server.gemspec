# frozen_string_literal: true

version = File.read(File.expand_path("../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name        = "activestorage-hotcell-server"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "The operations a cell runs on behalf of Active Storage."
  spec.description = <<~TEXT
    Transformations, image analysis, PDF and video previews, and media probing, written as HotCell
    operations so they run in an unprivileged container with no network rather than in the application.

    Despite the name, this gem does not load Active Storage. The name says which consumer it serves, not
    what it links against: a cell that loaded an application framework would have loaded its configuration
    and its credentials with it.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]

  spec.add_dependency "hotcell-server", version
  spec.add_dependency "image_processing", ">= 2.0"
  spec.add_dependency "mini_magick", ">= 4.0"
  spec.add_dependency "ruby-vips", ">= 2.2"
end
