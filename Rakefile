# frozen_string_literal: true

# The three hotcell gems need no tools and no container: their suites run on fixture operations in a few
# seconds, and so does the development cell the battery drives. The two activestorage-hotcell gems convert
# real files and need libvips, mutool, ffmpeg and ffprobe installed. That split is a design property rather
# than an accident, so the tasks keep it visible: `test:hotcell` is what CI runs on a machine with nothing
# installed, and on macOS.
HOTCELL = %w[ hotcell-core hotcell-client hotcell-server ].freeze
ACTIVE_STORAGE = %w[ activestorage-hotcell-server activestorage-hotcell-client ].freeze
GEMS = (HOTCELL + ACTIVE_STORAGE).freeze

# The VERSION file is what every gemspec builds against. These constants are what each gem reports once
# it is installed, and the file does not travel inside any gem, so they are written from it rather than
# read from it. Each gem's version_test.rb fails on one left behind.
VERSION_FILES = %w[
  hotcell-core/lib/hot_cell/core/version.rb
  hotcell-client/lib/hot_cell/client/version.rb
  hotcell-server/lib/hot_cell/server/version.rb
  activestorage-hotcell-client/lib/active_storage/hot_cell/client/version.rb
  activestorage-hotcell-server/lib/active_storage/hot_cell/server/version.rb
].freeze

def suites(*names)
  names.flatten.map { |name| "test:gem:#{name}" }
end

namespace "test" do
  namespace "gem" do
    GEMS.each do |name|
      desc "Run the #{name} test suite"
      task name do
        puts "\n## Running #{name} test suite"
        Dir.chdir(name) { sh "rake", "test" }
      end
    end
  end

  desc "Boot the real development cell on the example operations and run the battery"
  task :devcell do
    puts "\n## Running the battery against the development cell"
    ruby "examples/devcell"
  end

  desc "Check the conformance gate observes each isolation flag and sets no stack ulimit"
  task :gate do
    puts "\n## Checking the conformance gate"
    ruby "examples/gate"
  end

  desc "Run everything that needs no tools installed"
  task hotcell: suites(HOTCELL) + [ "test:gate", "test:devcell" ]

  desc "Run everything that needs the converters installed"
  task activestorage: suites(ACTIVE_STORAGE)
end

desc "Run every test suite"
task test: [ "test:hotcell", "test:activestorage" ]

namespace "version" do
  # With an argument it writes the VERSION file first, so a release is one command:
  # `rake version:bump[0.2.0]`. Without one it propagates whatever the file already says, for a VERSION
  # edited by hand.
  desc "Write VERSION and rewrite each gem's version constant from it"
  task :bump, [ :version ] do |_task, args|
    File.write "VERSION", "#{args[:version]}\n" if args[:version]
    version = File.read("VERSION").strip

    VERSION_FILES.each do |file|
      ruby = File.read(file)
      pattern = /^(\s*)VERSION = .*$/
      raise "#{file} declares no VERSION" unless ruby.match?(pattern)

      File.write file, ruby.sub(pattern, "\\1VERSION = #{version.inspect}")
    end

    puts "hotcell #{version}"
  end
end

# Releasing is a manual local process: build here, check the five gems, and push them by hand. Each
# gem's suite has the test that catches a constant left behind by a version bump.
desc "Build all five gems into pkg/"
task :gems do
  require "fileutils"

  version = File.read("VERSION").strip

  # Emptied rather than added to, so that `gem push pkg/*.gem` cannot reach a previous release's files.
  FileUtils.rm_rf "pkg"
  FileUtils.mkdir_p "pkg"

  GEMS.each do |name|
    Dir.chdir(name) { sh "gem", "build", "#{name}.gemspec", "--output", "../pkg/#{name}-#{version}.gem" }
  end

  puts "\n## Built hotcell #{version}"
  Dir["pkg/*-#{version}.gem"].sort.each { |path| puts "  #{File.expand_path(path)}" }
end

# One configuration and one run for all five gems, because the style is one style.
desc "Check style"
task :rubocop do
  sh "rubocop"
end

task default: [ :test, :rubocop ]

# markdown-toc is optional: a machine without it skips regeneration rather than failing.
desc "Regenerate the tables of contents in README.md, CONTRIBUTING.md and docs/DEPLOYMENT.md"
task :toc do
  require "mkmf"
  if find_executable0("markdown-toc")
    sh "markdown-toc --maxdepth=3 -i README.md"
    sh "markdown-toc --maxdepth=3 -i CONTRIBUTING.md"
    sh "markdown-toc --maxdepth=3 -i docs/DEPLOYMENT.md"
  else
    puts "WARN: cannot find markdown-toc, skipping. Install it with 'npm install -g markdown-toc'."
  end
end
