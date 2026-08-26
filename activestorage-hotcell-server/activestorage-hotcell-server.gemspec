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
    The HotCell operations behind activestorage-hotcell-client: image transformation with libvips or
    ImageMagick, image and media analysis, PDF previews with mutool or poppler, and video previews with
    ffmpeg. Install it in the cell, with the tools the operations you load require.
  TEXT

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/v#{version}/#{spec.name}"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/v#{version}/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[ "lib/**/*", "MIT-LICENSE", "README.md" ]

  spec.add_dependency "hotcell-server", version
  spec.add_dependency "image_processing", ">= 2.1.0"
  spec.add_dependency "mini_magick", ">= 5.4.0"
  spec.add_dependency "ruby-vips", ">= 2.2.1"
end
