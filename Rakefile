# frozen_string_literal: true

# The three hotcell gems need no converter and no container: their suites run on fixture operations in a few
# seconds. The two activestorage-hotcell gems convert real files and need libvips, mutool, ffmpeg and ffprobe
# installed. That split is a design property rather than an accident, so the tasks keep it visible.
HOTCELL = %w[ hotcell-core hotcell-client hotcell-server ].freeze
ACTIVE_STORAGE = %w[ activestorage-hotcell-server activestorage-hotcell-client ].freeze
GEMS = (HOTCELL + ACTIVE_STORAGE).freeze

MUTATING = %w[ hotcell-client hotcell-server activestorage-hotcell-server ].freeze

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

desc "Break each control in turn and confirm the suites notice"
task :mutations do
  MUTATING.each do |name|
    puts name
    Dir.chdir(name) { sh "rake", "mutations" }
  end
end

task default: :test
