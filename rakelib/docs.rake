# frozen_string_literal: true

# The reference pages under docs/ carry OKF frontmatter (https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md):
# a `type`, a `title`, a one-line `description`, and the `sources` a page describes. The indexes are generated
# from the descriptions, and `sources` is what lets a change to the code name the page it may have made wrong.
module HotCellDocs
  ROOT = "docs"
  INDEX = "index.md"
  MARKERS = /(<!-- index -->\n).*?(<!-- indexstop -->)/m

  Page = Struct.new(:path, :frontmatter) do
    def title = frontmatter["title"]
    def description = frontmatter["description"]
    def sources = Array(frontmatter["sources"])
    def order = frontmatter["order"].is_a?(Integer) ? frontmatter["order"] : Float::INFINITY

    def describes?(file)
      sources.any? { |source| file == source || file.start_with?("#{source.chomp("/")}/") }
    end
  end

  class << self
    def pages
      Dir[File.join(ROOT, "**", "*.md")].sort.reject { |path| File.basename(path) == INDEX }.map do |path|
        Page.new(path, frontmatter(path))
      end
    end

    def frontmatter(path)
      text = File.read(path)
      return {} unless text.start_with?("---\n")

      require "yaml"
      YAML.safe_load(text[4...text.index("\n---\n", 4)]) || {}
    end

    def indexes
      Dir[File.join(ROOT, "**", INDEX)].sort
    end

    # Each index lists the pages in its own directory, then the indexes of the directories below it. A page with
    # an `order` comes first, in that order; the rest follow by path.
    def listing(index)
      directory = File.dirname(index)
      own_pages = pages.select { |page| File.dirname(page.path) == directory }
        .sort_by.with_index { |page, position| [ page.order, position ] }
      entries = own_pages.map { |page| [ page.path, page.frontmatter ] } +
        indexes.filter_map { |other| [ other, frontmatter(other) ] if File.dirname(File.dirname(other)) == directory }

      rows = entries.map do |path, frontmatter|
        "| [#{frontmatter["title"]}](#{path.delete_prefix("#{directory}/")}) | #{frontmatter["description"]} |"
      end

      [ "| Page | Description |", "| --- | --- |", *rows ].join("\n")
    end

    def regenerated(index)
      File.read(index).sub(MARKERS) { "#{$1}\n#{listing(index)}\n\n#{$2}" }
    end

    def problems
      pages.flat_map { |page| page_problems(page) } + indexes.filter_map { |index| index_problem(index) }
    end

    def page_problems(page)
      %w[ type title description ].reject { |key| page.frontmatter[key].is_a?(String) && !page.frontmatter[key].empty? }
        .map { |key| "#{page.path}: frontmatter has no #{key}" } +
        (page.frontmatter.fetch("order", 0).is_a?(Integer) ? [] : [ "#{page.path}: order is not an integer" ]) +
        page.sources.reject { |source| File.exist?(source) }.map { |source| "#{page.path}: source #{source} does not exist" }
    end

    def index_problem(index)
      if !File.read(index).match?(MARKERS)
        "#{index}: no index markers"
      elsif File.read(index) != regenerated(index)
        "#{index}: out of date; run `rake docs:index`"
      end
    end

    # Pages whose sources changed since `base` while the page itself did not.
    def stale(base)
      changed = IO.popen([ "git", "diff", "--name-only", "#{base}...HEAD" ], &:read).lines(chomp: true)
      raise "git diff against #{base} failed" unless $?.success?

      pages.reject { |page| changed.include?(page.path) }.filter_map do |page|
        touched = changed.select { |file| page.describes?(file) }
        [ page, touched ] if touched.any?
      end
    end
  end
end

namespace "docs" do
  desc "Regenerate the page lists in docs/index.md and every other index.md under docs/"
  task :index do
    HotCellDocs.indexes.each { |index| File.write index, HotCellDocs.regenerated(index) }
  end

  desc "Check the docs' frontmatter, that every source exists, and that the indexes are current"
  task :check do
    problems = HotCellDocs.problems
    abort problems.join("\n") if problems.any?

    puts "docs: #{HotCellDocs.pages.size} pages, frontmatter, sources and indexes in order"
  end

  # A reminder rather than a gate: most changes to a source do not change what its page says.
  desc "List docs whose sources changed since BASE (default origin/master) while the doc did not"
  task :stale do
    base = ENV.fetch("BASE", "origin/master")

    HotCellDocs.stale(base).each do |page, touched|
      message = "#{touched.join(", ")} changed; check that #{page.path} still describes it"
      puts ENV["GITHUB_ACTIONS"] ? "::warning file=#{page.path}::#{message}" : "#{page.path}: #{message}"
    end
  end
end
