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

# The narrowed deadline and the operation name ride one control line, and the supervisor drops an
# over-limit report whole. A long enough name takes the deadline with it, and the supervisor then holds the
# request to the cell's maximum instead of the one the operation asked for.
class WorkerReportSizeTest < RegistryIsolatedTest
  def setup
    super
    @control = UNIXSocket.pair(:STREAM)
    @worker = HotCell::Worker.new slot: HotCell::Slot.build(Dir.mktmpdir("hotcell-report-size"), 0),
                                  configuration: HotCell::Configuration.new,
                                  control: HotCell::Connection.new(@control.last),
                                  log: HotCell::Log.null
  end

  def teardown
    @control.each { |socket| socket.close unless socket.closed? }
    super
  end

  def test_a_long_operation_name_does_not_displace_the_narrowed_deadline
    operation = Class.new(HotCell::Operation) do
      operation "test.#{"x" * 1200}"
      limits deadline: 1
    end

    assert_reports_the_deadline operation
  end

  # A short name that encodes long. JSON writes a NUL as six bytes, so 167 of them are 167 bytes of name
  # and 1002 of report: a budget set on the name passes this, and the report is still dropped.
  def test_a_name_that_escapes_long_does_not_displace_the_narrowed_deadline_either
    operation = Class.new(HotCell::Operation) do
      operation "\x00" * 167
      limits deadline: 1
    end

    assert_reports_the_deadline operation
  end

  private
    def assert_reports_the_deadline(operation)
      @worker.instance_variable_set :@op, operation.operation_name
      @worker.send :report_deadline, operation

      line = @control.first.gets
      assert_operator line.bytesize, :<=, HotCell::Worker::DISPATCH_BYTES,
                      "the supervisor drops a report this size whole, narrowed deadline and all"
      assert_equal 1, JSON.parse(line, symbolize_names: true)[:deadline]
    end
end
