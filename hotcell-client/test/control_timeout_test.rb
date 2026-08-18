# frozen_string_literal: true

require "test_helper"

# `describe` and `metrics` are the calls that report a cell's health, so they must not inherit the patience
# of the calls that do work.
class ControlTimeoutTest < HotCellClientTest
  class RecordingTransport
    attr_reader :calls

    def initialize
      @calls = []
    end

    # The defaults are Transport::Socket's own, so this records what a caller overrode rather than what it
    # passed. The work path overrides neither.
    def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
      @calls << { line: line, socket: socket, timeout: timeout }
      HotCell::Response.parse %({"ok":true,"result":{}})
    end
  end

  class Echo < HotCell::Client
    hotcell "test"
    operation "test.echo"
  end

  def test_the_control_socket_and_the_work_socket_are_bounded_separately
    transport = RecordingTransport.new
    HotCell.root = "/nowhere"
    cell = HotCell.register "test", timeout: 300, control_timeout: 3, transport: transport,
                                    permanent: Unprocessable, transient: TemporarilyUnavailable

    cell.describe
    cell.metrics
    Echo.perform_in_hotcell [], [], {}

    control, work = transport.calls.partition { |recorded| recorded[:socket].end_with?("control.sock") }

    assert_equal [ 3, 3 ], control.map { |recorded| recorded[:timeout] }
    assert_equal [ 300 ], work.map { |recorded| recorded[:timeout] }
  end

  def test_a_cell_bounds_its_control_calls_at_five_seconds_unless_told_otherwise
    assert_equal 5, HotCell.register("test").control_timeout
    assert_equal 0.5, HotCell.register("other", control_timeout: 0.5).control_timeout
  end

  # The bound has to fire, not merely be plumbed. This cell accepts the connection and never answers, which
  # is what a wedged supervisor looks like from here — and what the work timeout used to make the caller
  # wait out.
  #
  # The work timeout is 2 rather than a realistic 300 so that a control call which regresses to using it
  # fails this test in two seconds instead of hanging the suite for five minutes. The message names the
  # number, so the two are still told apart.
  def test_a_cell_that_accepts_and_never_answers_gives_up_at_the_control_timeout
    with_unanswering_cell(timeout: 2, control_timeout: 0.2) do |cell|
      response = cell.metrics

      refute_predicate response, :ok?
      assert_equal "timeout", response.failure.code
      assert_match "did not answer within 0.2s", response.failure.message
    end
  end

  # A shorter bound is only safe because nothing in the gem takes a less careful path when a control call
  # fails. `describe` warns and returns nil, boot carries on, and no operation is assumed to be present.
  def test_a_control_timeout_never_fails_open
    with_unanswering_cell(timeout: 2, control_timeout: 0.2) do |cell|
      warnings = capturing_warnings { assert_nil cell.describe }

      assert_match "could not describe the cell", warnings
      assert_equal({ "test" => nil }, HotCell.describe_cells)
    end
  end

  private
    # A cell whose sockets exist and whose supervisor never writes a byte back.
    #
    # The prefix is two characters because the whole path has to fit a `sockaddr_un`, which holds 104 bytes
    # on Darwin. A macOS runner's `Dir.tmpdir` is around fifty of them before this adds a name, a cell
    # directory and `control.sock`, and "hotcell-unanswering" put it two bytes over.
    def with_unanswering_cell(name: "test", **register)
      Dir.mktmpdir "hc" do |root|
        directory = File.join(root, name)
        Dir.mkdir directory

        control = UNIXServer.new File.join(directory, "control.sock")
        UNIXServer.new File.join(directory, "work.sock")

        # The accepted connections are held rather than dropped, because a closed peer would answer
        # `unavailable` and prove nothing about the timeout.
        held = []
        accepter = Thread.new { loop { held << control.accept } }

        HotCell.root = root
        yield HotCell.register(name, permanent: Unprocessable, transient: TemporarilyUnavailable, **register)
      ensure
        accepter&.kill
        held&.each(&:close)
        control&.close
      end
    end

    def capturing_warnings
      captured = StringIO.new
      HotCell.logger = Logger.new(captured)
      yield
      captured.string
    ensure
      HotCell.logger = Logger.new(File::NULL)
    end
end
