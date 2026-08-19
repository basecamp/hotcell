# frozen_string_literal: true

# The three hotcell gems need no tools and no container: their suites run on fixture operations in a few
# seconds, and so does the development cell the battery drives. The two activestorage-hotcell gems convert
# real files and need libvips, mutool, ffmpeg and ffprobe installed. That split is a design property rather
# than an accident, so the tasks keep it visible: `test:hotcell` is what CI runs on a machine with nothing
# installed, and on macOS.
HOTCELL = %w[ hotcell-core hotcell-client hotcell-server ].freeze
ACTIVE_STORAGE = %w[ activestorage-hotcell-server activestorage-hotcell-client ].freeze
GEMS = (HOTCELL + ACTIVE_STORAGE).freeze

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

  desc "Run everything that needs no tools installed"
  task hotcell: suites(HOTCELL) + [ "test:devcell" ]

  desc "Run everything that needs the converters installed"
  task activestorage: suites(ACTIVE_STORAGE)
end

desc "Run every test suite"
task test: [ "test:hotcell", "test:activestorage" ]

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
