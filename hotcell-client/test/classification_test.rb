# frozen_string_literal: true

require "test_helper"

# Every failure a client can produce, classified. The transport is a seam, so this drives each verdict
# straight through it rather than arranging a cell to produce it.
#
# Anything a client can raise that the consuming application does not classify becomes a user-facing 500.
# That is not hypothetical: applications carry rails_ext patches that exist because
# `system(exception: true)` raised a bare RuntimeError outside their rescue lists.
class ClassificationTest < HotCellClientTest
  # Only the verdicts something actually knew: an operation naming what it could not decode, a caller
  # breaking the protocol, and the two limits this request provably hit by itself.
  PERMANENT = [
    { code: "unreadable" },
    { code: "invalid" },
    { code: "killed", cause: "fsize" },
    { code: "killed", cause: "memory" },
  ].freeze

  # `failed` and `crashed` sit here rather than above, and both used to be permanent. `failed` is whatever
  # exception nobody classified, which includes a full disk; `crashed` is a death this process cannot
  # attribute to the input the worker was holding. Neither is grounds for writing a file off forever.
  TRANSIENT = [
    { code: "protocol" },
    { code: "unsupported" },
    { code: "capacity" },
    { code: "unavailable" },
    { code: "timeout" },
    { code: "failed" },
    { code: "killed", cause: "deadline" },
    { code: "killed", cause: "crashed" },
  ].freeze

  def test_every_permanent_code_raises_the_injected_permanent_class
    PERMANENT.each do |failure|
      register_with failed(**failure)

      assert_raises Unprocessable, "expected #{failure.inspect} to be permanent" do
        Anything.perform_in_hotcell [], [], {}
      end
    end
  end

  def test_every_transient_code_raises_the_injected_transient_class
    TRANSIENT.each do |failure|
      register_with failed(**failure)

      assert_raises TemporarilyUnavailable, "expected #{failure.inspect} to be transient" do
        Anything.perform_in_hotcell [], [], {}
      end
    end
  end

  def test_the_two_lists_between_them_cover_every_code_the_taxonomy_defines
    covered = (PERMANENT + TRANSIENT).map { |failure| failure[:code] }.uniq.sort

    assert_equal HotCell::Codes::PERMANENT.keys.push(HotCell::Codes::KILLED).sort, covered
  end

  def test_every_killed_cause_is_covered
    covered = (PERMANENT + TRANSIENT).filter_map { |failure| failure[:cause] }.sort

    assert_equal HotCell::Codes::PERMANENT_BY_CAUSE.keys.sort, covered
  end

  def test_the_raised_message_carries_enough_to_re_decide_on_later
    register_with failed(code: "unreadable", error_class: "Vips::Error", message: "bad PNG header")

    error = assert_raises(Unprocessable) { Anything.perform_in_hotcell [], [], {} }

    assert_match "unreadable", error.message
    assert_match "Vips::Error", error.message
    assert_match "bad PNG header", error.message
  end

  # Applications rescue broadly around representations, so "raise" is indistinguishable from "placeholder"
  # and contract skew is otherwise invisible. An application running several clients against several
  # independently-booted cells needs to know which one skewed.
  def test_contract_skew_gets_its_own_reporting_hook
    reported = []
    register_with failed(code: "protocol"), on_contract_skew: ->(error, cell) { reported << [ error, cell ] }

    assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }

    assert_equal 1, reported.size
    assert_kind_of TemporarilyUnavailable, reported.first.first
    assert_equal "test", reported.first.last.name
  end

  def test_nothing_else_reaches_the_contract_skew_hook
    reported = []
    register_with failed(code: "capacity"), on_contract_skew: ->(*args) { reported << args }

    assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }

    assert_empty reported
  end

  def test_a_success_returns_the_result_with_its_keys_symbolized
    register_with HotCell::Response.ok(result: { width: 800, height: 600 })

    assert_equal({ width: 800, height: 600 }, Anything.perform_in_hotcell([], [], {}))
  end

  # A cold side configured to treat unreadable as data rather than as an error would otherwise make those
  # requests invisible, and unreadable rates are exactly what you want to watch after a library upgrade.
  def test_the_event_carries_the_code_even_though_the_call_raised
    register_with failed(code: "capacity")

    events = events_for do
      assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }
    end

    assert_equal 1, events.size
    assert_equal "capacity", events.first.payload[:code]
    assert_equal "test", events.first.payload[:cell]
    assert_equal "test.anything", events.first.payload[:operation]
  end

  # `code` alone cannot classify a kill: `killed` is permanent for fsize and memory and transient for
  # deadline and crashed. A subscriber that only had the code filed every fsize kill as transient. So the
  # event carries what the Failure knows — the cause, the signal, and the verdict itself.
  def test_the_event_carries_the_cause_and_the_verdict_so_a_subscriber_can_classify_a_kill
    register_with failed(code: "killed", cause: "fsize", signal: "XFSZ")

    event = events_for do
      assert_raises(Unprocessable) { Anything.perform_in_hotcell [], [], {} }
    end.first.payload

    assert_equal "killed", event[:code]
    assert_equal "fsize", event[:cause]
    assert_equal "XFSZ", event[:signal]
    assert_equal true, event[:permanent]
  end

  def test_the_event_carries_a_transient_verdict_for_a_deadline_kill
    register_with failed(code: "killed", cause: "deadline")

    event = events_for do
      assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }
    end.first.payload

    assert_equal "deadline", event[:cause]
    assert_nil event[:signal]
    assert_equal false, event[:permanent]
  end

  def test_the_event_carries_no_code_on_success
    register_with HotCell::Response.ok(result: {}, timing: { perform_ms: 12, operation_ms: 9 })

    event = events_for { Anything.perform_in_hotcell [], [], {} }.first.payload

    assert_nil event[:code]
    assert_nil event[:cause]
    assert_nil event[:signal]
    assert_nil event[:permanent]
    assert_equal 12, event[:perform_ms]
    assert_equal({ perform_ms: 12, operation_ms: 9 }, event[:timing])
  end

  # The client never reconnects and never retries. A silent retry doubles a cell's load at the moment it is
  # least able to take it.
  def test_a_failure_is_sent_exactly_once
    transport = register_with failed(code: "unavailable")

    assert_raises(TemporarilyUnavailable) { Anything.perform_in_hotcell [], [], {} }

    assert_equal 1, transport.calls.size
  end

  class FakeTransport
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def call(_cell, line, descriptors, socket: nil, timeout: nil)
      @calls << { line: line, descriptors: descriptors, socket: socket, timeout: timeout }
      @response.respond_to?(:call) ? @response.call : @response
    end
  end

  class Anything < HotCell::Client
    hotcell "test"
    operation "test.anything"
  end

  # The cell is the untrusted side, so its answer is untrusted bytes and every way of failing to read one
  # has to land inside the taxonomy. JSON.parse raises EncodingError rather than JSON::ParserError for a
  # key holding bytes that are not valid UTF-8, and Transport::Socket rescues neither by name — so a
  # hostile cell could raise an exception in the application that no code, no verdict and no
  # `perform.hot_cell` event described, past whatever the caller had arranged to rescue.
  def test_an_answer_that_cannot_be_read_is_a_verdict_rather_than_an_escaping_exception
    hostile = %({"v":1,"ok":true,"result":{"\xff\xfe":1},"timing":{}}\n).b

    with_cell_answering(hostile) do
      error = assert_raises TemporarilyUnavailable do
        Anything.perform_in_hotcell [], [], {}
      end

      assert_match "could not be read", error.message
    end
  end

  private
    # A cell whose supervisor answers one fixed line and closes, so the client reads exactly these bytes.
    def with_cell_answering(line, name: "test")
      Dir.mktmpdir "hotcell-hostile" do |root|
        directory = File.join(root, name)
        Dir.mkdir directory

        work = UNIXServer.new File.join(directory, "work.sock")
        answerer = Thread.new do
          loop do
            socket = work.accept
            socket.write line
            socket.close
          end
        end

        HotCell.root = root
        HotCell.register name, permanent: Unprocessable, transient: TemporarilyUnavailable
        yield
      ensure
        answerer&.kill
        work&.close
      end
    end

    def register_with(response, **options)
      FakeTransport.new(response).tap do |transport|
        HotCell.root = "/nowhere"
        HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable,
                                 transport: transport, **options
      end
    end

    def failed(code:, cause: nil, signal: nil, error_class: nil, message: nil)
      HotCell::Response.failed HotCell::Failure.new(code: code, cause: cause, signal: signal,
                                                    error_class: error_class, message: message),
                               timing: { perform_ms: 1 }
    end
end
