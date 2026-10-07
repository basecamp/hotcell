# frozen_string_literal: true

# Ruby 1.9.3 can read this file, because Bundler evaluates a gemspec on the application's own Ruby when the
# gem comes from a path or a git source. So no `__dir__` and no squiggly heredoc.
version = File.read(File.expand_path("../../VERSION", __FILE__)).strip

Gem::Specification.new do |spec|
  spec.name        = "hotcell-client-legacy"
  spec.version     = version
  spec.authors     = [ "Mike Dalessio" ]
  spec.email       = [ "mike@37signals.com" ]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/basecamp/hotcell"
  spec.summary     = "Call a HotCell from a legacy Ruby version, with no dependencies."
  spec.description = "Call an operation in a HotCell container from an application that cannot run " \
                     "hotcell-client. One file, the standard library only, and legacy Ruby versions."

  spec.required_ruby_version = ">= 1.9.3"

  # RubyGems 1.8, which Ruby 1.9.3 ships, has no metadata.
  if spec.respond_to?(:metadata)
    spec.metadata["homepage_uri"]    = spec.homepage
    spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
    spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
    spec.metadata["documentation_uri"] = "https://basecamp.github.io/hotcell/"
    spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
    spec.metadata["rubygems_mfa_required"] = "true"
  end

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]
end
