# frozen_string_literal: true

version = File.read(File.expand_path("../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name        = "hotcell-server"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "Run a HotCell: the supervisor, the worker, and the operation API."
  spec.description = <<~TEXT
    Runs a HotCell container. A supervisor listens on two Unix sockets, forks a worker for each request,
    and enforces a wall clock deadline and resource limits on it. Write the work as a subclass of
    HotCell::Operation.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "exe/**/*", "MIT-LICENSE", "README.md" ]
  spec.bindir = "exe"
  spec.executables = [ "hotcell", "hotcell-health" ]

  spec.add_dependency "hotcell-core", version
end
