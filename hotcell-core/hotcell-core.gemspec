# frozen_string_literal: true

version = File.read(File.expand_path("../VERSION", __dir__)).strip

Gem::Specification.new do |spec|
  spec.name        = "hotcell-core"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "The wire protocol shared by both sides of a HotCell."
  spec.description = <<~TEXT
    HotCell runs untrusted media conversion in an unprivileged sibling container with no network,
    reached over a Unix socket that carries file descriptors rather than paths or bytes.

    This gem holds what both sides must agree on: the request and response format, SCM_RIGHTS
    marshalling, descriptor access-mode verification, payload validation, and the error taxonomy.
    It performs no I/O of its own and loads no media library.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]  = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]
end
