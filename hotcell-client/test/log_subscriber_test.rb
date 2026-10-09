# frozen_string_literal: true

require "test_helper"
require "hot_cell/log_subscriber"
require "stringio"
require "timeout"

class LogSubscriberTest < HotCellClientTest
  FORGERY = "libgomp: Thread creation failed\nforged\u0085forged\u2028forged\u2029forged"

  def setup
    super
    @previous_logger = ActiveSupport::LogSubscriber.logger
    @log = StringIO.new
    ActiveSupport::LogSubscriber.logger = Logger.new(@log, formatter: ->(severity, _, _, message) { "#{severity} #{message}\n" })
    HotCell::LogSubscriber.attach_to :hot_cell
  end

  def teardown
    HotCell::LogSubscriber.detach_from :hot_cell
    ActiveSupport::LogSubscriber.logger = @previous_logger
    super
  end

  def test_a_call_logs_one_line_with_the_cell_the_operation_and_both_clocks
    with_cell do
      with_files("hello") do |source, destination|
        reading(source) { |input| writing(destination) { |output| Uppercase.perform_in_hotcell input, output } }
      end
    end

    assert_equal 1, @log.string.lines.size
    assert_match(/\AINFO   HotCell \(\d+\.\dms\) \{/, @log.string)

    fields = logged_fields
    assert_equal "test", fields["cell"]
    assert_equal "test.uppercase", fields["operation"]
    assert_equal "ok", fields["code"]
    assert_equal 5, fields["bytes_in"]
    assert_equal 5, fields["bytes_out"]
    assert_kind_of Numeric, fields["perform_ms"]
    assert_kind_of Numeric, fields["duration_ms"]
  end

  # The line is the only record of a crash's diagnosis when the caller discards the failure rather than
  # retrying it. The stderr is hostile text, so it must arrive escaped inside the one line, including the
  # Unicode line separators that JSON leaves raw and that a log viewer may still break on.
  def test_a_failed_call_logs_its_code_its_cause_and_its_stderr
    with_cell do
      assert_raises TemporarilyUnavailable do
        StderrWriter.perform_in_hotcell [], [], text: FORGERY, fatal: true
      end
    end

    assert_equal 1, @log.string.split(/\R/).size

    fields = logged_fields
    assert_equal "killed", fields["code"]
    assert_equal "crashed", fields["cause"]
    assert_match FORGERY, fields["stderr"]
  end

  # An exception that escapes the call, such as the application's own request timeout, still fires the event.
  def test_a_call_interrupted_by_an_exception_logs_code_interrupted_and_the_exception
    HotCell.root = "/nowhere"
    HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable,
                             transport: ->(*) { raise Timeout::Error, "the request ran out of time" }

    assert_raises(Timeout::Error) { Uppercase.perform_in_hotcell [], [], {} }

    fields = logged_fields
    assert_equal "test", fields["cell"]
    assert_equal "test.uppercase", fields["operation"]
    assert_equal "interrupted", fields["code"]
    assert_equal "Timeout::Error", fields["exception"]
  end

  class Uppercase < HotCell::Client
    hotcell "test"
    operation "test.uppercase"
  end

  class StderrWriter < HotCell::Client
    hotcell "test"
    operation "test.stderr_writer"
  end

  private
    def logged_fields
      JSON.parse(@log.string[/\{.*\}/])
    end
end
