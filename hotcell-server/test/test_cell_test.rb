# frozen_string_literal: true

require "test_helper"

# The suite's own harness. A cell that refuses a connection never reads it: accept_work writes the
# capacity answer and closes. A test client descheduled between connecting and writing then fails its
# send against the closed peer — with the verdict it came for already queued on its socket.
class TestCellTest < HotCellServerTest
  # Yields a connection the test prepared instead of dialing a cell, which pins the losing side of the
  # race: the peer has answered and closed before send_line writes a byte.
  class RefusedBeforeSending < TestCell
    attr_writer :prepared

    def connect(_name = "work.sock")
      yield @prepared
    end
  end

  def test_send_line_returns_a_verdict_that_arrived_before_the_request_was_written
    cell_side, caller_side = UNIXSocket.pair(:STREAM)
    cell_side.write HotCell::Response.failed(HotCell::Failure.new(code: "capacity",
                                                                  message: "the queue is full at 0")).to_line
    cell_side.close

    cell = RefusedBeforeSending.new
    cell.prepared = HotCell::Connection.new(caller_side)

    assert_failed "capacity", cell.send_line(request_line("test.echo"))
  ensure
    caller_side&.close
    cell&.cleanup
  end
end
