# frozen_string_literal: true

require_relative "lib/hot_cell/server/version"

Gem::Specification.new do |spec|
  spec.name        = "hotcell-server"
  spec.version     = HotCell::SERVER_VERSION
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "Run a HotCell: the supervisor, the worker, and the operation API."
  spec.description = <<~TEXT
    The cell side of HotCell. A supervisor listens on two Unix sockets, forks a worker per request,
    holds each worker to a wall-clock deadline and a set of resource limits, and answers for one that
    dies without reporting.

    An operation subclasses HotCell::Operation, declares its limits, and implements perform. This gem
    deliberately depends on no application framework: nothing about it loads ActiveSupport, because a
    sandbox should carry only what the conversion needs.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[ "lib/**/*", "exe/**/*", "MIT-LICENSE", "README.md" ]
  spec.bindir = "exe"
  spec.executables = [ "hotcell", "hotcell-health" ]

  spec.add_dependency "hotcell-core", HotCell::SERVER_VERSION
end
