# frozen_string_literal: true

GEMS = %w[ hotcell-core hotcell-client hotcell-server ].freeze

GEMS.each do |name|
  desc "Run the #{name} test suite"
  task name do
    Dir.chdir(name) { sh "rake", "test" }
  end
end

desc "Run every test suite"
task test: GEMS

task default: :test
