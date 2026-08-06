# frozen_string_literal: true

require_relative "lib/hot_cell/core/version"

Gem::Specification.new do |spec|
  spec.name        = "hotcell-core"
  spec.version     = HotCell::CORE_VERSION
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
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]
end
