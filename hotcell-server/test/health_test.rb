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

  # A supervisor that accepts and then dies answers nothing, and end of stream reached the parser as nil.
  # That raised TypeError from inside JSON, so a probe whose whole job is saying why reported a backtrace.
  def test_a_cell_that_answers_nothing_says_so
    Dir.mktmpdir do |directory|
      server = UNIXServer.new File.join(directory, "control.sock")
      # Read the request before closing, or the probe's own write is reset and it reports that instead.
      closer = Thread.new do
        loop do
          socket = server.accept
          socket.gets
          socket.close
        end
      end

      output, status = Open3.capture2e({ "HOTCELL_DIR" => directory }, RbConfig.ruby, EXE)

      refute_predicate status, :success?
      assert_match "closed the connection without answering", output
      refute_match "TypeError", output
    ensure
      closer&.kill
      server&.close
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
