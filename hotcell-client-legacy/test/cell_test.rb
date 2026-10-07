# frozen_string_literal: true

require "test_helper"

# The client against a real cell, which bin/test boots on a Ruby new enough for hotcell-server.
class CellTest < LegacyTest
  def test_a_conversion_crosses_the_boundary_and_comes_back
    with_files("hello from the cold side") do |source, destination|
      result = File.open(source, "rb") do |input|
        File.open(destination, "wb") { |output| client.perform "test.uppercase", [ input ], [ output ] }
      end

      assert_equal({ "bytes" => 24 }, result)
      assert_equal "HELLO FROM THE COLD SIDE", File.binread(destination)
    end
  end

  def test_a_single_input_and_output_need_no_array
    with_files("hello") do |source, destination|
      File.open(source, "rb") do |input|
        File.open(destination, "wb") { |output| client.perform "test.uppercase", input, output }
      end

      assert_equal "HELLO", File.binread(destination)
    end
  end

  def test_a_payload_and_a_result_round_trip_with_string_keys
    result = client.perform("test.echo", [], [], "format" => "png", "resize" => [ 800, 600 ])

    assert_equal({ "echoed" => { "format" => "png", "resize" => [ 800, 600 ] } }, result)
  end

  def test_a_permanent_failure_raises_permanent_failure
    error = assert_raises(HotCell::Client::Legacy::PermanentFailure) { client.perform "test.undecodable", [], [] }

    assert_equal "unreadable", error.hot_cell_failure.code
    assert_match "not an image at all", error.message
  end

  def test_a_transient_failure_raises_transient_failure
    error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.broken", [], [] }

    assert_equal "failed", error.hot_cell_failure.code
  end

  def test_an_operation_the_cell_does_not_carry_is_transient
    error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.nonexistent", [], [] }

    assert_equal "unsupported", error.hot_cell_failure.code
  end

  # The client checks no access mode, so the cell's own check is what refuses a writable input.
  def test_a_writable_input_is_refused_by_the_cell_as_invalid
    with_files("hello") do |source, destination|
      error = File.open(source, "r+b") do |input|
        File.open(destination, "wb") do |output|
          assert_raises(HotCell::Client::Legacy::PermanentFailure) { client.perform "test.uppercase", input, output }
        end
      end

      assert_equal "invalid", error.hot_cell_failure.code
    end
  end

  def test_a_cell_that_answers_too_late_is_a_transient_timeout
    error = nil
    took = elapsed do
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) do
        client(timeout: 0.5).perform "test.blocking", [], [], "seconds" => 5
      end
    end

    assert_equal "timeout", error.hot_cell_failure.code
    assert_operator took, :<, 2
  end

  def test_a_kill_carries_its_cause
    error = assert_raises(HotCell::Client::Legacy::TransientFailure) do
      client(timeout: 10).perform "test.impatient", [], []
    end

    assert_equal "killed", error.hot_cell_failure.code
    assert_equal "deadline", error.hot_cell_failure.cause
  end

  def test_the_group_can_read_an_input_and_write_an_output
    with_files("hello") do |source, destination|
      File.open(source, "rb") do |input|
        File.open(destination, "wb") do |output|
          client(group: Process.gid).perform "test.uppercase", input, output
        end
      end

      assert_equal 0o640, File.stat(source).mode & 0o777
      assert_equal 0o620, File.stat(destination).mode & 0o777
    end
  end
end
