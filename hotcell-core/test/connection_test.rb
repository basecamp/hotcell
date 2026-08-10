# frozen_string_literal: true

require "test_helper"

class ConnectionTest < HotCellTest
  def setup
    @cold, @hot = UNIXSocket.pair(:STREAM)
  end

  def teardown
    [ @cold, @hot ].each { |socket| socket.close unless socket.closed? }
  end

  def test_a_message_and_its_descriptors_cross_together
    with_files("source") do |source, destination|
      reading(source) do |readable|
        writing(destination) do |writable|
          request = HotCell::Request.new(op: "test.copy", inputs: 1, outputs: 1)
          descriptors = [ HotCell::Input.new(readable), HotCell::Output.new(writable) ]
          cold.send_message request.to_line, descriptors: descriptors

          line, received = hot.receive_message

          assert_equal "test.copy", HotCell::Request.parse(line).op
          assert_equal 2, received.size
          assert_equal "source", received.first.read
        ensure
          received&.each(&:close)
        end
      end
    end
  end

  def test_the_access_modes_survive_the_crossing
    with_files("source") do |source, destination|
      reading(source) do |readable|
        writing(destination) do |writable|
          cold.send_message HotCell::Request.new(op: "test.copy", inputs: 1, outputs: 1).to_line,
                            descriptors: [ HotCell::Input.new(readable), HotCell::Output.new(writable) ]

          _line, received = hot.receive_message

          assert_instance_of HotCell::Input, HotCell::Input.new(received.first)
          assert_instance_of HotCell::Output, HotCell::Output.new(received.last)
        ensure
          received&.each(&:close)
        end
      end
    end
  end

  def test_a_message_with_no_descriptors_crosses
    cold.send_message HotCell::Request.new(op: "hotcell.metrics").to_line

    line, received = hot.receive_message

    assert_equal "hotcell.metrics", HotCell::Request.parse(line).op
    assert_empty received
  end

  # A stream socket does not promise that one sendmsg arrives as one recvmsg. The kernel will not glue a
  # message carrying descriptors to one that follows it, so sending both before reading forces the split
  # rather than hoping for it.
  def test_a_line_that_arrives_in_fragments_is_assembled
    with_file("source") do |source|
      reading(source) do |readable|
        head = '{"v":1,"op":"test.copy","inputs":1,'
        tail = %("outputs":0,"payload":{}}\n)

        cold.socket.sendmsg head, 0, nil, Socket::AncillaryData.unix_rights(readable)
        cold.socket.sendmsg tail

        line, received = hot.receive_message

        assert_equal head + tail, line
        assert_equal 1, received.size
      ensure
        received&.each(&:close)
      end
    end
  end

  def test_descriptors_are_taken_from_whichever_fragment_carried_them
    with_file("source") do |source|
      reading(source) do |readable|
        cold.socket.sendmsg '{"v":1,"op":"test.copy","inputs":1,'
        cold.socket.sendmsg %("outputs":0,"payload":{}}\n), 0, nil,
                            Socket::AncillaryData.unix_rights(readable)

        line, received = hot.receive_message

        assert_equal 1, received.size
        assert_equal "source", received.first.read
        assert_equal 1, HotCell::Request.parse(line).inputs
      ensure
        received&.each(&:close)
      end
    end
  end

  def test_bytes_after_the_line_are_refused_because_one_connection_carries_one_message
    cold.socket.write %({"v":1,"op":"a","inputs":0,"outputs":0,"payload":{}}\n{"v":1,"op":"b"}\n)

    error = assert_raises(HotCell::MessageError) { hot.receive_message }
    assert_match "bytes follow the message line", error.message
  end

  def test_a_peer_that_closed_without_sending_reports_no_line
    cold.close

    line, received = hot.receive_message

    assert_nil line
    assert_empty received
  end

  def test_a_line_that_ends_without_a_newline_is_refused
    cold.socket.write '{"v":1,"op":"a","inputs":0,"outputs":0,"payload":{}}'
    cold.close

    error = assert_raises(HotCell::MessageError) { hot.receive_message }
    assert_match "with no newline", error.message
  end

  def test_an_oversized_line_is_refused_without_leaking_its_descriptors
    before = open_descriptors

    with_file("source") do |source|
      reading(source) do |readable|
        cold.socket.sendmsg "x" * 4096, 0, nil, Socket::AncillaryData.unix_rights(readable)
        3.times { cold.socket.sendmsg "x" * 4096 }

        assert_raises(HotCell::MessageError) { hot.receive_message }
      end
    end

    assert_equal before, open_descriptors
  end

  def test_a_response_line_comes_back
    hot.write_line HotCell::Response.ok(result: { width: 800 }).to_line

    assert_equal({ width: 800 }, HotCell::Response.parse(cold.read_line).result)
  end

  def test_a_response_that_never_arrives_reports_no_line
    hot.close

    assert_nil cold.read_line
  end

  def test_an_oversized_response_is_refused
    hot.socket.write "x" * (HotCell::MAX_RESPONSE_BYTES + 1)

    assert_raises(HotCell::MessageError) { cold.read_line }
  end

  private
    def cold
      @cold_connection ||= HotCell::Connection.new(@cold)
    end

    def hot
      @hot_connection ||= HotCell::Connection.new(@hot)
    end
end
