# frozen_string_literal: true

# The three hotcell gems need no tools and no container: their suites run on fixture operations in a few
# seconds. The two activestorage-hotcell gems convert real files and need libvips, mutool, ffmpeg and ffprobe
# installed. That split is a design property rather than an accident, so the tasks keep it visible.
HOTCELL = %w[ hotcell-core hotcell-client hotcell-server ].freeze
ACTIVE_STORAGE = %w[ activestorage-hotcell-server activestorage-hotcell-client ].freeze
GEMS = (HOTCELL + ACTIVE_STORAGE).freeze

namespace "test" do
  GEMS.each do |name|
    desc "Run the #{name} test suite"
    task name do
      puts "\n## Running #{name} test suite"
      Dir.chdir(name) { sh "rake", "test" }
    end
  end

  desc "Boot the real development cell on the example operations and run the battery"
  task :devcell do
    puts "\n## Running the battery against the development cell"
    ruby "examples/devcell"
  end
end

desc "Run every test suite"
task test: GEMS.map { |name| "test:#{name}" } + [ "test:devcell" ]

desc "Run only the suites that need no tools installed"
task hotcell: HOTCELL.map { |name| "test:#{name}" } + [ "test:devcell" ]

desc "Run only the suites that need the converters installed"
task activestorage: ACTIVE_STORAGE.map { |name| "test:#{name}" }

# One configuration and one run for all five gems, because the style is one style.
desc "Check style"
task :rubocop do
  sh "rubocop"
end

task default: [ :test, :rubocop ]
