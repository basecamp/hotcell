# frozen_string_literal: true

require "test_helper"

# Every way an answer can fail to arrive, or arrive garbled, is transient: none of them says anything about
# the input, so none may be written down against it.
class TransportTest < LegacyTest
  def test_a_socket_that_does_not_exist_is_unavailable
    client = HotCell::Client::Legacy.new(File.join(Dir.tmpdir, "no-such-cell", "work.sock"))
    error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

    assert_equal "unavailable", error.code
  end

  # A supervisor that stops calling accept leaves its backlog full, where a blocking connect on Linux would wait
  # in the kernel with no deadline at all. Darwin refuses the connection instead, which is unavailable.
  def test_the_deadline_covers_a_connect_to_a_full_backlog
    Dir.mktmpdir do |directory|
      path = File.join(directory, "work.sock")
      listener = Socket.new(:UNIX, :STREAM)
      listener.bind Socket.sockaddr_un(path)
      listener.listen 1
      pending = fill_backlog(path)

      begin
        client = HotCell::Client::Legacy.new(path, timeout: 0.5)
        call = Thread.new do
          begin
            client.perform "test.echo", [], []
          rescue HotCell::Client::Legacy::TransientFailure => error
            error
          end
        end

        assert call.join(2), "the call waited on a cell whose backlog is full"
        assert_includes %w[timeout unavailable], call.value.code
      ensure
        call.kill if call
        pending.each { |socket| socket.close }
        listener.close
      end
    end
  end

  # A peer that trickles a byte at a time would never trip a deadline that each read restarts.
  def test_the_deadline_covers_the_whole_answer_rather_than_each_read
    trickle = lambda { |connection| 40.times { connection.write " "; sleep 0.1 } }
    with_peer(trickle) do |client|
      error = nil
      took = elapsed { error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] } }

      assert_equal "timeout", error.code
      assert_operator took, :<, 2
    end
  end

  # A request bigger than the socket's buffer, to a peer that never reads, blocks the writes after the first
  # sendmsg.
  def test_the_deadline_covers_a_send_the_peer_never_reads
    Dir.mktmpdir do |directory|
      path = File.join(directory, "work.sock")
      server = UNIXServer.new(path)
      peer = Thread.new { connection = server.accept; sleep; connection }

      begin
        client = HotCell::Client::Legacy.new(path, timeout: 0.5)
        call = Thread.new do
          begin
            client.perform "test.echo", [], [], "padding" => "x" * 4_000_000
          rescue HotCell::Client::Legacy::TransientFailure => error
            error
          end
        end

        assert call.join(2), "the call waited on a peer that never reads"
        assert_equal "timeout", call.value.code
      ensure
        call.kill if call
        peer.kill
        server.close
      end
    end
  end

  def test_an_answer_that_passes_the_size_limit_without_a_newline_is_unavailable
    oversize = lambda { |connection| connection.write "x" * (HotCell::Client::Legacy::MAX_RESPONSE_BYTES + 1) }
    with_peer(oversize) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal "unavailable", error.code
    end
  end

  def test_an_answer_cut_off_before_its_newline_is_unavailable
    partial = lambda { |connection| connection.write %({"v":1,"ok":true,"result":{}}); connection.close }
    with_peer(partial) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal "unavailable", error.code
    end
  end

  def test_a_connection_closed_with_no_answer_is_unavailable
    with_peer(lambda { |connection| connection.close }) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal "unavailable", error.code
    end
  end

  def test_an_answer_that_is_not_json_is_unavailable
    with_peer(lambda { |connection| connection.write "not json\n" }) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal "unavailable", error.code
    end
  end

  def test_ok_must_be_true_rather_than_truthy
    with_peer(lambda { |connection| connection.write %({"v":1,"ok":"true","result":{}}\n) }) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal "unavailable", error.code
    end
  end

  def test_the_permanent_flag_decides_even_for_a_code_this_client_has_never_heard_of
    answer = %({"v":1,"ok":false,"error":{"code":"novel","permanent":true}}\n)
    with_peer(lambda { |connection| connection.write answer }) do |client|
      error = assert_raises(HotCell::Client::Legacy::PermanentFailure) { client.perform "test.echo", [], [] }

      assert_equal "novel", error.code
    end
  end

  def test_a_failure_is_permanent_only_when_the_flag_is_true
    [ %("permanent":"true"), %("permanent":1), %("other":true) ].each do |flag|
      answer = %({"v":1,"ok":false,"error":{"code":"unreadable",#{flag}}}\n)
      with_peer(lambda { |connection| connection.write answer }) do |client|
        error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

        assert_equal false, error.error[:permanent]
      end
    end
  end

  # Ruby before 2.2 never frees a Symbol, so a key the cell chooses must not become one.
  def test_keys_the_cell_chooses_do_not_become_symbols
    answers = [ %({"v":1,"ok":true,"result":{"result_key_from_the_cell":1}}\n),
                %({"v":1,"ok":false,"error":{"code":"failed","error_key_from_the_cell":1}}\n) ]
    answers.each do |answer|
      with_peer(lambda { |connection| connection.write answer }) do |client|
        begin
          client.perform "test.echo", [], []
        rescue HotCell::Client::Legacy::TransientFailure
          nil
        end
      end
    end

    names = Symbol.all_symbols.map { |symbol| symbol.to_s }
    refute_includes names, "result_key_from_the_cell"
    refute_includes names, "error_key_from_the_cell"
  end

  # JSON.parse passes raw bytes that are not UTF-8 straight through, on every json from 1.5 to 3.0.
  def test_a_failures_text_is_valid_utf_8_whatever_the_cell_sent
    answer = "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"unreadable\",\"permanent\":true,\"message\":\"bad \xff bytes\"}}\n"
    with_peer(lambda { |connection| connection.write answer }) do |client|
      error = assert_raises(HotCell::Client::Legacy::PermanentFailure) { client.perform "test.echo", [], [] }

      assert error.error[:message].valid_encoding?
      assert error.message.valid_encoding?
      assert_match "bad  bytes", error.message
    end
  end

  def test_a_failure_carries_only_the_protocols_fields
    answer = "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"failed\",\"cause\":[\"\xff\"],\"details\":{\"m\":\"\xff\"}}}\n"
    with_peer(lambda { |connection| connection.write answer }) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal [ :permanent, :code, :cause ], error.error.keys
      assert error.error[:cause].valid_encoding?
    end
  end

  def test_a_failures_text_is_capped_and_stderr_keeps_its_tail
    answer = %({"v":1,"ok":false,"error":{"code":"failed","message":"#{"m" * 2000}","stderr":"#{"n" * 2000}fatal"}}\n)
    with_peer(lambda { |connection| connection.write answer }) do |client|
      error = assert_raises(HotCell::Client::Legacy::TransientFailure) { client.perform "test.echo", [], [] }

      assert_equal HotCell::Client::Legacy::MAX_FIELD_BYTES, error.error[:message].bytesize
      assert_equal HotCell::Client::Legacy::MAX_FIELD_BYTES, error.error[:stderr].bytesize
      assert error.error[:stderr].end_with?("fatal")
    end
  end

  private
    # Until the kernel refuses a connection, as hotcell-client's ControlTimeoutTest does. A hundred connections
    # did not fill the backlog on the macOS CI runner.
    def fill_backlog(path)
      pending = []
      loop do
        socket = Socket.new(:UNIX, :STREAM)
        pending << socket
        socket.connect_nonblock Socket.sockaddr_un(path)
      end
    rescue Errno::EAGAIN, Errno::ECONNREFUSED
      pending
    end
end
