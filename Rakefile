# frozen_string_literal: true

GEMS = %w[ hotcell-core hotcell-client hotcell-server ].freeze
MUTATING_GEMS = %w[ hotcell-client hotcell-server ].freeze

GEMS.each do |name|
  desc "Run the #{name} test suite"
  task name do
    Dir.chdir(name) { sh "rake", "test" }
  end
end

desc "Run every test suite"
task test: GEMS

desc "Break each control in turn and confirm the suites notice"
task :mutations do
  MUTATING_GEMS.each do |name|
    puts name
    Dir.chdir(name) { sh "rake", "mutations" }
  end
end

task default: :test
