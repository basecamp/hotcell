# frozen_string_literal: true

require "test_helper"

# Not required at the top of this file: a cell inherits what the test process defined, and requiring
# the probes here would serve them from every cell the suite boots and hide the opt-in.
class HealthOperationsTest < HotCellServerTest
  PROBES = -> { require "hot_cell/health_operations" }

  def test_a_cell_that_has_not_required_them_does_not_serve_them
    TestCell.boot do |cell|
      with_files("hello") do |source, destination|
        response = cell.call "health.echo", inputs: [ source ], outputs: [ destination ]

        assert_equal "unsupported", response.failure.code
      end
    end
  end

  def test_echo_returns_the_message_through_the_caller_s_own_descriptors
    TestCell.boot(operations: PROBES) do |cell|
      with_files("hello from the cold side") do |source, destination|
        response = cell.call "health.echo", inputs: [ source ], outputs: [ destination ]

        assert_ok response
        assert_equal "hello from the cold side", File.binread(destination)
        refute response.result[:staged], "echo reads the descriptors, so nothing reaches scratch"
      end
    end
  end

  # /dev/fd/N is a fresh open, so this fails on a cell that holds the descriptors but cannot open
  # the caller's files by name.
  def test_reopen_returns_the_message_through_both_paths
    TestCell.boot(operations: PROBES) do |cell|
      with_files("hello from the cold side") do |source, destination|
        response = cell.call "health.reopen", inputs: [ source ], outputs: [ destination ]

        assert_ok response
        assert_equal "hello from the cold side", File.binread(destination)
      end
    end
  end
end
