# frozen_string_literal: true

# The site is built from a staged copy of the repository's docs: README.md becomes the home page and docs/ keeps
# its own path, so the links between them work unchanged. A link that leaves both, to an ADR or a source file,
# would 404 on the site; staging points it at GitHub instead.
module HotCellSite
  STAGING = "tmp/site/staging"
  BLOB = "https://github.com/basecamp/hotcell/blob/master"
  TREE = "https://github.com/basecamp/hotcell/tree/master"
  LINK = /(\]\()([^)\s#]+)(#[^)\s]*)?(\))/

  # Zensical is pre-1.0 and changes often, so its version is pinned. Its dependencies are held to what was
  # published by the date; bump both together.
  ZENSICAL = "uvx --exclude-newer 2026-10-05 --from zensical==0.0.67 zensical"

  class << self
    def stage
      require "fileutils"

      FileUtils.rm_rf STAGING
      FileUtils.mkdir_p STAGING
      FileUtils.cp_r "docs", STAGING
      stage_page "README.md", "index.md"
      Dir["docs/**/*.md"].each { |path| stage_page path, path }
    end

    def stage_page(source, destination)
      File.write File.join(STAGING, destination), relink(File.read(source), source, destination)
    end

    def relink(text, source, destination)
      text.gsub(LINK) do
        prefix, target, fragment, suffix = $1, $2, $3, $4
        "#{prefix}#{retarget(target, source, destination)}#{fragment}#{suffix}"
      end
    end

    def retarget(target, source, destination)
      return target if target.match?(%r{\A[a-z]+:})

      path = File.expand_path(target, File.dirname("/#{source}")).delete_prefix("/")
      if path == "README.md"
        relative("index.md", destination)
      elsif path.start_with?("docs/")
        relative(path, destination)
      else
        "#{File.directory?(path) ? TREE : BLOB}/#{path}"
      end
    end

    def relative(path, from)
      require "pathname"
      Pathname.new(path).relative_path_from(File.dirname(from)).to_s
    end
  end
end

namespace "site" do
  desc "Stage README.md and docs/ for the site in #{HotCellSite::STAGING}"
  task :stage do
    HotCellSite.stage
  end

  desc "Build the documentation site into tmp/site/build"
  task build: :stage do
    sh "#{HotCellSite::ZENSICAL} build --clean"
  end

  desc "Serve the documentation site at http://localhost:8000 with live reload"
  task serve: :stage do
    sh "#{HotCellSite::ZENSICAL} serve"
  end
end
