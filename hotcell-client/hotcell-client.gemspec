# frozen_string_literal: true

version = File.read(File.expand_path("../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name        = "hotcell-client"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "Call a HotCell from an application."
  spec.description = <<~TEXT
    The application side of HotCell. Register the cells a deployment runs, subclass HotCell::Client to
    name one, and call it with descriptors and a payload.

    The client owns everything a caller needs to respond correctly to a cell that is saturated,
    restarting, or absent: the classification of every error into permanent and transient, the
    exception classes an application injects for each, and instrumentation through
    ActiveSupport::Notifications.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]

  spec.add_dependency "hotcell-core", version
  spec.add_dependency "activesupport", ">= 7.1"
end
