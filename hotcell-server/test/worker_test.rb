# frozen_string_literal: true

require "test_helper"

# What a worker reports about a request it never got to serve.
class WorkerTest < HotCellServerTest
  def setup
    @control = UNIXSocket.pair(:STREAM)
    @client = UNIXSocket.pair(:STREAM)
    @worker = HotCell::Worker.new slot: HotCell::Slot.build(Dir.mktmpdir("hotcell-worker"), 0),
                                  configuration: HotCell::Configuration.new,
                                  control: HotCell::Connection.new(@control.last),
                                  log: HotCell::Log.null
  end

  def teardown
    (@control + @client).each { |socket| socket.close unless socket.closed? }
  end

  # A caller that connects and closes before sending its request left `response` nil, and the ensure
  # reported idle with the default code `"ok"` — so the supervisor counted a success nobody received.
  # A connection that carried no request is transient `unavailable`, never a success.
  def test_a_connection_that_closes_before_a_request_is_reported_unavailable
    @client.first.close

    @worker.send :serve, HotCell::Connection.new(@client.last), 0

    assert_equal({ idle: true, code: "unavailable" }, report)
  end

  # A home the worker cannot create is a broken deployment, not a verdict on the document — and a request
  # that never ran must not be reported as one that succeeded. Creating it used to sit outside the begin, so
  # the failure left the caller with no response while the supervisor was told idle `"ok"`.
  def test_a_home_that_cannot_be_created_is_reported_failed
    slot = @worker.send :slot
    File.symlink File.join(slot.directory, "nowhere"), slot.directory

    @worker.send :serve, HotCell::Connection.new(@client.last), 0

    assert_equal({ idle: true, code: "failed" }, report)
  end

  private
    def report
      raise "the worker never reported" unless @control.first.wait_readable(1)

      JSON.parse @control.first.gets, symbolize_names: true
    end
end
