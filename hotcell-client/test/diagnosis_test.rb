# frozen_string_literal: true

require "test_helper"

class DiagnosisTest < HotCellClientTest
  class RecordingTransport
    attr_reader :sockets

    def initialize
      @sockets = []
    end

    def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
      @sockets << socket
      HotCell::Response.parse %({"ok":true,"result":{}})
    end
  end

  class AnsweringTransport
    def initialize(bytes:, result:)
      @bytes = bytes
      @result = result
    end

    def call(cell, _line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
      descriptors.last.to_io.syswrite @bytes if socket == cell.work_socket
      HotCell::Response.parse JSON.generate(ok: true, result: @result)
    end
  end

  class DescribeRefusingTransport
    def call(_cell, line, _descriptors, **)
      if line.include?(HotCell::DESCRIBE)
        HotCell::Response.parse %({"ok":false,"error":{"code":"protocol","message":"no such thing"}})
      else
        HotCell::Response.parse %({"ok":true,"result":{}})
      end
    end
  end

  HEALTH_OPERATIONS = -> { require "hot_cell/health_operations" }

  def test_healthy_when_every_registered_cell_answers_describe_and_metrics
    with_cell do
      diagnosis = HotCell.diagnose

      assert_predicate diagnosis, :healthy?
      assert_equal %i[ describe metrics ], diagnosis.cells["test"].keys
    end
  end

  def test_unhealthy_when_any_registered_cell_does_not_answer
    [ :before, :after ].each do |order|
      HotCell.reset_registrations!
      HotCell.register "missing", dir: "/nonexistent/hotcell/missing" if order == :before

      with_cell do
        HotCell.register "missing", dir: "/nonexistent/hotcell/missing" if order == :after

        refute_predicate HotCell.diagnose, :healthy?, "the missing cell was registered #{order} the one that answers"
      end
    end
  end

  def test_unhealthy_for_a_registered_cell_with_no_socket_directory
    HotCell.register "test"

    diagnosis = HotCell.diagnose

    refute_predicate diagnosis, :healthy?
    assert_match(/no socket directory/, diagnosis.cells["test"][:metrics][:error])
  end

  def test_unhealthy_when_describe_fails_and_metrics_answers
    HotCell.register "test", dir: "/nowhere/test", transport: DescribeRefusingTransport.new

    diagnosis = HotCell.diagnose

    refute_predicate diagnosis, :healthy?
    assert_match(/no such thing/, diagnosis.cells["test"][:describe][:error])
  end

  def test_logs_nothing_for_a_cell_that_describe_would_warn_about
    log = StringIO.new
    HotCell.logger = Logger.new(log)

    with_cell register: { timeout: 0.5 } do
      assert_predicate HotCell.diagnose, :healthy?
    end

    assert_empty log.string
  end

  def test_unhealthy_when_no_cell_is_registered
    refute_predicate HotCell.diagnose, :healthy?
  end

  def test_asks_only_the_control_socket_unless_work_is_requested
    transport = RecordingTransport.new
    HotCell.register "test", dir: "/nowhere/test", transport: transport

    HotCell.diagnose

    assert_equal [ "/nowhere/test/control.sock" ], transport.sockets.uniq
  end

  def test_work_round_trips_echo_and_reopen_through_the_work_socket
    with_cell operations: HEALTH_OPERATIONS do
      diagnosis = HotCell.diagnose(work: true)

      assert_predicate diagnosis, :healthy?
      assert_equal %i[ describe metrics echo reopen ], diagnosis.cells["test"].keys
    end
  end

  def test_work_is_unhealthy_when_a_round_trip_returns_nothing
    HotCell.register "test", dir: "/nowhere/test", transport: RecordingTransport.new

    diagnosis = HotCell.diagnose(work: true)

    refute_predicate diagnosis, :healthy?
    assert_match(/wrote no bytes/, diagnosis.cells["test"][:echo][:error])
    assert_match(/wrote no bytes/, diagnosis.cells["test"][:reopen][:error])
  end

  def test_work_is_unhealthy_when_the_cell_returns_other_bytes
    HotCell.register "test", dir: "/nowhere/test", transport: AnsweringTransport.new(bytes: "HOTCELL", result: {})

    assert_match(/other bytes than it was sent/, HotCell.diagnose(work: true).cells["test"][:echo][:error])
  end

  def test_work_is_unhealthy_when_the_input_was_staged
    HotCell.register "test", dir: "/nowhere/test", transport: AnsweringTransport.new(bytes: "hotcell", result: { staged: true })

    assert_match(/staged/, HotCell.diagnose(work: true).cells["test"][:reopen][:error])
  end

  def test_work_is_unhealthy_when_the_cell_does_not_serve_the_health_operations
    with_cell do
      refute_predicate HotCell.diagnose(work: true), :healthy?
    end
  end

  def test_reports_when_and_where_it_was_taken
    diagnosis = HotCell.diagnose.as_json

    assert_equal Socket.gethostname, diagnosis[:host]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, diagnosis[:at])
    assert_equal false, diagnosis[:healthy]
  end
end
