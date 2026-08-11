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

  private
    def report
      raise "the worker never reported" unless @control.first.wait_readable(1)

      JSON.parse @control.first.gets, symbolize_names: true
    end
end
