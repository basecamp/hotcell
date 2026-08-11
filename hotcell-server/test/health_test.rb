# frozen_string_literal: true

require "test_helper"
require "open3"

# The healthcheck command a Docker HEALTHCHECK runs inside the container, where network: none does not
# apply. It asks the supervisor for describe on the control socket, which answers even when the work
# socket is saturated — so healthy means "the supervisor is alive and answering", not "a worker is free".
class HealthTest < HotCellServerTest
  EXE = File.expand_path("../exe/hotcell-health", __dir__)

  def test_a_running_cell_is_healthy
    TestCell.boot do |cell|
      output, status = Open3.capture2e({ "HOTCELL_DIR" => cell.directory }, RbConfig.ruby, EXE)

      assert_predicate status, :success?, "expected health to pass: #{output}"
    end
  end

  def test_a_missing_cell_is_unhealthy
    Dir.mktmpdir do |empty|
      output, status = Open3.capture2e({ "HOTCELL_DIR" => empty }, RbConfig.ruby, EXE)

      refute_predicate status, :success?, "expected health to fail with no cell listening"
      assert_match "unhealthy", output
    end
  end
end
