# frozen_string_literal: true

# The three hotcell gems need no converter and no container: their suites run on fixture operations in a few
# seconds. The two activestorage-hotcell gems convert real files and need libvips, mutool, ffmpeg and ffprobe
# installed. That split is a design property rather than an accident, so the tasks keep it visible.
HOTCELL = %w[ hotcell-core hotcell-client hotcell-server ].freeze
ACTIVE_STORAGE = %w[ activestorage-hotcell-server activestorage-hotcell-client ].freeze
GEMS = (HOTCELL + ACTIVE_STORAGE).freeze

GEMS.each do |name|
  desc "Run the #{name} test suite"
  task name do
    Dir.chdir(name) { sh "rake", "test" }
  end
end

desc "Run every test suite"
task test: GEMS

desc "Run only the suites that need no converter installed"
task hotcell: HOTCELL

# One configuration and one run for all five gems, because the style is one style.
desc "Check style"
task :rubocop do
  sh "rubocop"
end

task default: [ :test, :rubocop ]
