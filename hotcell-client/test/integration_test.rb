# frozen_string_literal: true

require "test_helper"

# The client against a real cell, over a real socket, passing real descriptors.
class IntegrationTest < HotCellClientTest
  def test_a_conversion_crosses_the_boundary_and_comes_back
    with_cell do
      with_files("hello from the cold side") do |source, destination|
        result = reading(source) do |input|
          writing(destination) { |output| Uppercase.perform_in_hotcell [ input ], [ output ], {} }
        end

        assert_equal 24, result[:bytes]
        assert_equal "HELLO FROM THE COLD SIDE", File.binread(destination)
      end
    end
  end

  def test_a_single_input_and_output_need_no_array
    with_cell do
      with_files("hello") do |source, destination|
        result = reading(source) do |input|
          writing(destination) { |output| Uppercase.perform_in_hotcell input, output }
        end

        assert_equal 5, result[:bytes]
        assert_equal "HELLO", File.binread(destination)
      end
    end
  end

  def test_a_payload_and_a_result_both_round_trip_with_symbol_keys
    with_cell do
      payload = { format: "png", operations: { resize_to_limit: [ 800, 600 ] } }

      assert_equal payload, Echo.perform_in_hotcell([], [], payload)[:echoed]
    end
  end

  def test_an_undecodable_input_raises_the_applications_permanent_class
    with_cell do
      error = assert_raises(Unprocessable) { Undecodable.perform_in_hotcell [], [], {} }

      assert_match "unreadable", error.message
      assert_match "not an image at all", error.message
    end
  end

  # A full tmpfs on the cell arrives exactly this way, as ENOSPC from the copy rather than from the socket,
  # and a full filesystem must never be recorded as "this document is unprocessable".
  def test_success_with_an_empty_output_is_transient_rather_than_a_valid_empty_image
    with_cell do
      with_files do |source, destination|
        error = reading(source) do |input|
          writing(destination) do |output|
            assert_raises(TemporarilyUnavailable) { Silent.perform_in_hotcell [ input ], [ output ], {} }
          end
        end

        assert_match "received no bytes", error.message
      end
    end
  end

  # The cell answers first now, which is why the case above no longer reaches this. It stays because it is a
  # different defence against the same fact: the client cannot tell whether a cell it does not control
  # checked, and `ok` with nothing written must never become a valid empty image.
  def test_the_client_refuses_an_empty_output_even_when_the_cell_called_it_ok
    HotCell.root = "/nowhere"
    HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable,
                             transport: ->(*) { HotCell::Response.ok(result: {}, timing: {}) }

    with_files do |source, destination|
      error = reading(source) do |input|
        writing(destination) do |output|
          assert_raises(TemporarilyUnavailable) { Silent.perform_in_hotcell [ input ], [ output ], {} }
        end
      end

      assert_match "wrote no bytes", error.message
    end
  end

  def test_a_cell_that_is_not_there_is_transient
    HotCell.root = Dir.mktmpdir "hotcell-absent"
    HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable

    error = assert_raises(TemporarilyUnavailable) { Echo.perform_in_hotcell [], [], {} }

    assert_match "unavailable", error.message
  end

  def test_the_clients_own_deadline_is_transient_and_says_it_was_the_clients
    with_cell(deadline: 30, register: { timeout: 0.3 }) do
      error = assert_raises(TemporarilyUnavailable) do
        Blocking.perform_in_hotcell [], [], { seconds: 3 }
      end

      assert_match "timeout", error.message
      assert_match "did not answer within 0.3s", error.message
    end
  end

  # One request per connection invites a retry on ECONNREFUSED, and a silent retry doubles a cell's load at
  # the moment it is least able to take it. Retry belongs in the job layer, which is what the transient class
  # is for.
  def test_a_client_connects_once_and_does_not_try_again
    Dir.mktmpdir "hotcell-counting" do |root|
      Dir.mkdir File.join(root, "test")
      HotCell.root = root
      HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable

      with_counting_server File.join(root, "test", "work.sock") do |connections|
        assert_raises(TemporarilyUnavailable) { Echo.perform_in_hotcell [], [], {} }

        wait_until(what: "the connection to be counted") { connections.call.positive? }

        assert_equal 1, connections.call, "a retry would have happened before the raise above"
      end
    end
  end

  def test_the_event_carries_the_sizes_on_both_sides
    with_cell do
      with_files("four") do |source, destination|
        events = events_for do
          reading(source) do |input|
            writing(destination) { |output| Uppercase.perform_in_hotcell [ input ], [ output ], {} }
          end
        end

        assert_equal 4, events.first.payload[:bytes_in]
        assert_equal 4, events.first.payload[:bytes_out]
      end
    end
  end

  def test_the_event_breaks_the_cells_own_time_down
    with_cell do
      event = events_for { Echo.perform_in_hotcell [], [], {} }.first.payload

      assert_operator event[:perform_ms], :>=, 0
      [ :queued_ms, :operation_ms, :perform_ms ].each do |key|
        assert event[:timing].key?(key), "expected #{key} in #{event[:timing].inspect}"
      end
    end
  end

  def test_describe_reports_what_each_registered_cell_carries
    with_cell do
      described = HotCell.describe_cells

      assert_includes described["test"][:operations], "test.uppercase"
      assert_equal HotCell::PROTOCOL_VERSION, described["test"][:v]
    end
  end

  def test_describe_warns_when_this_client_would_give_up_before_the_cell_answers
    with_cell(deadline: 30, queue_wait: 10, register: { timeout: 5 }) do
      warnings = capturing_warnings { HotCell.describe_cells }

      assert_match "this client waits 5s and the cell says it may take 41s", warnings
      assert_match "a mistake for a background job", warnings
    end
  end

  # A cell too old to report its own budget says nothing rather than having the client guess at one.
  def test_describe_is_quiet_when_the_cell_does_not_report_a_budget
    with_cell(deadline: 30, queue_wait: 10, register: { timeout: 5 }) do
      cell = HotCell.cell("test")
      described = cell.send(:control, HotCell::DESCRIBE).result.except(:answer_within)

      warnings = capturing_warnings { cell.send :warn_about_timeout, described }

      refute_match "this client waits", warnings
    end
  end

  def test_describe_is_quiet_when_the_timeout_covers_the_cell
    with_cell(deadline: 5, queue_wait: 2, register: { timeout: 60 }) do
      refute_match "this client waits", capturing_warnings { HotCell.describe_cells }
    end
  end

  # Otherwise this is an `unsupported` on the first real request, which is a bad place to learn it.
  def test_describe_warns_when_the_cell_does_not_carry_what_a_client_wants
    with_cell do
      warnings = capturing_warnings { HotCell.describe_cells }

      assert_match "IntegrationTest::Absent wants \"test.absent\"", warnings
    end
  end

  # A cell that is down at app boot is a degraded deployment, not a broken one. An application that refuses
  # to start because its thumbnail cell is restarting is worse than one that serves placeholders.
  def test_describe_warns_and_carries_on_when_a_cell_does_not_answer
    HotCell.root = Dir.mktmpdir "hotcell-absent"
    HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable

    described = nil
    warnings = capturing_warnings { described = HotCell.describe_cells }

    assert_nil described["test"]
    assert_match "could not describe the cell", warnings
  end

  def test_describe_skips_a_cell_whose_path_is_turned_off
    HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable

    assert_nil HotCell.describe_cells["test"]
  end

  # Counts lag responses — the worker answers the caller before the supervisor reads its idle report and
  # increments the counter — so the wait is the assertion, exactly as in the server suite's metrics test.
  def test_metrics_come_back_through_the_registration
    with_cell do
      Echo.perform_in_hotcell [], [], {}

      wait_until(what: "the supervisor to count the request") do
        HotCell.cell("test").metrics.result[:requests][:total] == 1
      end
    end
  end

  class Uppercase < HotCell::Client
    hotcell "test"
    operation "test.uppercase"
  end

  class Echo < HotCell::Client
    hotcell "test"
    operation "test.echo"
  end

  class Undecodable < HotCell::Client
    hotcell "test"
    operation "test.undecodable"
  end

  class Silent < HotCell::Client
    hotcell "test"
    operation "test.silent"
  end

  class Blocking < HotCell::Client
    hotcell "test"
    operation "test.blocking"
  end

  # Named after nothing the cell carries, to prove the boot check notices.
  class Absent < HotCell::Client
    hotcell "test"
    operation "test.absent"
  end

  private
    def capturing_warnings
      captured = StringIO.new
      HotCell.logger = Logger.new(captured)
      yield
      captured.string
    ensure
      HotCell.logger = nil
    end

    # Counts on accept rather than after closing, so the number exists as early as it can. It is still
    # another thread, so a caller has to wait for it — see the assertion, which is sound because this client
    # is synchronous: by the time it has raised, every connection it was ever going to make has been made.
    def with_counting_server(path)
      server = UNIXServer.new(path)
      connections = 0
      accepting = Thread.new do
        loop do
          accepted = server.accept
          connections += 1
          accepted.close
        end
      rescue IOError, Errno::EBADF
        nil
      end

      yield -> { connections }
    ensure
      server&.close
      accepting&.kill
    end
end
