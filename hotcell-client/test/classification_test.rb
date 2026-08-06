# frozen_string_literal: true

require "test_helper"

# Every failure a client can produce, classified. The transport is a seam, so this drives each verdict
# straight through it rather than arranging a cell to produce it.
#
# Anything a client can raise that the consuming application does not classify becomes a user-facing 500.
# That is not hypothetical: HEY carries a rails_ext that exists because `system(exception: true)` raised a
# bare RuntimeError outside its rescue list.
class ClassificationTest < HotCellClientTest
  PERMANENT = [
    { code: "unreadable" },
    { code: "failed" },
    { code: "invalid" },
    { code: "killed", limit: "fsize" },
    { code: "killed", limit: "memory" },
    { code: "killed", limit: "signal" },
  ].freeze

  TRANSIENT = [
    { code: "protocol" },
    { code: "unsupported" },
    { code: "capacity" },
    { code: "unavailable" },
    { code: "timeout" },
    { code: "killed", limit: "deadline" },
    { code: "killed", limit: "crashed" },
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

    assert_equal HotCell::Codes::TERMINAL.keys.push(HotCell::Codes::KILLED).sort, covered
  end

  def test_every_killed_limit_is_covered
    covered = (PERMANENT + TRANSIENT).filter_map { |failure| failure[:limit] }.sort

    assert_equal HotCell::Codes::TERMINAL_BY_LIMIT.keys.sort, covered
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

  def test_the_event_carries_no_code_on_success
    register_with HotCell::Response.ok(result: {}, timing: { perform_ms: 12, convert_ms: 9 })

    event = events_for { Anything.perform_in_hotcell [], [], {} }.first.payload

    assert_nil event[:code]
    assert_equal 12, event[:perform_ms]
    assert_equal({ perform_ms: 12, convert_ms: 9 }, event[:timing])
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

  private
    def register_with(response, **options)
      FakeTransport.new(response).tap do |transport|
        HotCell.root = "/nowhere"
        HotCell.register "test", permanent: Unprocessable, transient: TemporarilyUnavailable,
                                 transport: transport, **options
      end
    end

    def failed(code:, limit: nil, error_class: nil, message: nil)
      HotCell::Response.failed HotCell::Failure.new(code: code, limit: limit, error_class: error_class,
                                                    message: message),
                               timing: { perform_ms: 1 }
    end
end
