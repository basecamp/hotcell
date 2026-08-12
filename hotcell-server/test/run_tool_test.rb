# frozen_string_literal: true

require "test_helper"

# run_tool's `pass:` hands a spawned tool one of the worker's own descriptors, so the tool reads it as
# /dev/fd/N without a byte being copied onto scratch. This is what lets an operation feed an input of any
# size to a tool under a file_size that bounds only what the worker writes.
class RunToolTest < HotCellServerTest
  def test_a_passed_descriptor_reaches_the_tool_through_dev_fd
    with_file("bytes the tool reads back through its own fd") do |source|
      TestCell.boot do |cell|
        result = assert_ok(cell.call("test.read_through_fd", inputs: [ source ])).result

        assert_equal "bytes the tool reads back through its own fd", result[:content]
        refute result[:staged], "the input was copied onto scratch instead of read in place"
      end
    end
  end

  # The point of reading in place: file_size bounds writes, and a passed descriptor is a read. An input
  # larger than the limit reaches the tool, where staging it would have died with SIGXFSZ. Kept under the
  # response limit so the whole input can ride back for the length check.
  def test_an_input_larger_than_the_write_limit_reaches_the_tool
    with_file("x" * (40 * 1024)) do |source|
      TestCell.boot(file_size: 16 * 1024) do |cell|
        result = assert_ok(cell.call("test.read_through_fd", inputs: [ source ])).result

        assert_equal 40 * 1024, result[:content].bytesize
        refute result[:staged], "a large input was staged instead of read in place"
      end
    end
  end
end
