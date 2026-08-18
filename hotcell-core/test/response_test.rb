# frozen_string_literal: true

require "test_helper"

class ResponseTest < HotCellTest
  def test_a_successful_response_round_trips_with_its_keys_symbolized
    response = HotCell::Response.ok(result: { width: 800, height: 600 }, timing: { perform_ms: 47 })
    parsed = HotCell::Response.parse(response.to_line)

    assert_predicate parsed, :ok?
    assert_equal({ width: 800, height: 600 }, parsed.result)
    assert_equal({ perform_ms: 47 }, parsed.timing)
  end

  def test_a_result_value_json_cannot_carry_raises
    response = HotCell::Response.ok(result: { format: :png })

    assert_raises(HotCell::SerializationError) { response.to_line }
  end

  def test_a_failed_response_round_trips
    failure = HotCell::Failure.new(code: "unreadable", error_class: "Vips::Error", message: "bad header")
    parsed = HotCell::Response.parse(HotCell::Response.failed(failure, timing: { perform_ms: 5 }).to_line)

    refute_predicate parsed, :ok?
    assert_equal "unreadable", parsed.failure.code
    assert_equal "Vips::Error", parsed.failure.error_class
    assert_equal "bad header", parsed.failure.message
    assert_predicate parsed.failure, :permanent?
  end

  def test_timing_is_present_on_a_failure_too
    line = HotCell::Response.failed(HotCell::Failure.new(code: "failed"), timing: { queued_ms: 3 }).to_line

    assert_equal({ queued_ms: 3 }, HotCell::Response.parse(line).timing)
  end

  # The flag is set by the side that knows and read back as data, not re-derived. That is what makes a
  # code added later safe: an old client will not recognise it but will still dispose of it correctly.
  def test_permanent_comes_off_the_wire_rather_than_being_re_derived
    line = '{"v":1,"ok":false,"error":{"code":"unreadable","permanent":false},"timing":{}}'

    refute_predicate HotCell::Response.parse(line).failure, :permanent?
  end

  def test_an_unrecognised_code_with_no_permanent_flag_is_not_permanent
    line = '{"v":1,"ok":false,"error":{"code":"something_added_later"},"timing":{}}'

    refute_predicate HotCell::Response.parse(line).failure, :permanent?
  end

  def test_killed_splits_on_the_limit_the_worker_hit
    assert_predicate HotCell::Failure.new(code: "killed", cause: "memory"), :permanent?
    assert_predicate HotCell::Failure.new(code: "killed", cause: "fsize"), :permanent?
    refute_predicate HotCell::Failure.new(code: "killed", cause: "deadline"), :permanent?
  end

  def test_the_wire_carries_only_the_fields_a_failure_has
    wire = HotCell::Failure.new(code: "capacity").to_h

    assert_equal({ code: "capacity", permanent: false }, wire)
  end

  def test_a_message_is_capped_in_bytes_at_the_cell
    failure = HotCell::Failure.new(code: "unreadable", message: "x" * 5000)

    assert_equal HotCell::Failure::MAX_MESSAGE_BYTES, failure.message.bytesize
  end

  # A cell that could not serialize its own error could not answer at all, and Vips::Error#message
  # routinely carries the input filename.
  def test_an_invalid_utf8_sequence_survives_to_a_usable_message_and_a_serializable_response
    failure = HotCell::Failure.new(code: "unreadable", message: "bad \xFF\xFE name".b)

    assert_equal "bad  name", failure.message
    assert_predicate failure.message, :valid_encoding?
    assert_match "bad  name", HotCell::Response.failed(failure).to_line
  end

  def test_capping_does_not_leave_half_a_character_behind
    message = "é" * HotCell::Failure::MAX_MESSAGE_BYTES
    failure = HotCell::Failure.new(code: "unreadable", message: message)

    assert_predicate failure.message, :valid_encoding?
    assert_operator failure.message.bytesize, :<=, HotCell::Failure::MAX_MESSAGE_BYTES
  end

  # The first assertion is the premise and the second is the behaviour. JSON.parse tags the string
  # UTF-8 and hands the invalid bytes through without complaint, so parsing is not a filter and the
  # client has to scrub for itself.
  def test_a_client_scrubs_again_because_json_parse_passes_invalid_utf8_straight_through
    line = %({"v":1,"ok":false,"error":{"code":"unreadable","permanent":true,"message":"bad \xFF name"},"timing":{}})
      .dup.force_encoding(Encoding::UTF_8)

    refute_predicate JSON.parse(line, symbolize_names: true).dig(:error, :message), :valid_encoding?
    assert_predicate HotCell::Response.parse(line).failure.message, :valid_encoding?
  end

  # Not only the message. All five fields arrive from the wire, all five reach `to_s`, the instrumentation
  # event and whatever a subscriber writes down, and `code` is the one applications store. Scrubbing one of
  # them left the same poisoned row reachable through a different key.
  def test_every_failure_field_is_scrubbed_and_not_only_the_message
    line = %({"v":1,"ok":false,"error":{"code":"unre\xFFadable","cause":"mem\xFFory","signal":"K\xFFILL",) +
           %("class":"Vips::E\xFFrror","message":"bad \xFF name"},"timing":{}})
      .dup.force_encoding(Encoding::UTF_8)

    failure = HotCell::Response.parse(line).failure

    [ failure.code, failure.cause, failure.signal, failure.error_class, failure.message ].each do |field|
      assert_predicate field, :valid_encoding?
    end
    assert_predicate failure.to_s, :valid_encoding?
  end

  def test_a_response_that_is_not_an_object
    assert_raises(HotCell::MessageError) { HotCell::Response.parse("[]\n") }
  end

  def test_a_failed_response_with_no_error_object
    assert_raises(HotCell::MessageError) { HotCell::Response.parse('{"v":1,"ok":false}') }
  end

  # `ok` is the field the whole taxonomy turns on, so it has to be the boolean it claims to be. Ruby's
  # truthiness would read every one of these as success, on a response carrying no result at all.
  def test_an_ok_that_is_not_a_boolean_is_refused
    [ '"false"', "0", "[]", "null", '"yes"' ].each do |value|
      line = %({"v":1,"ok":#{value},"result":{}}\n)

      error = assert_raises(HotCell::MessageError, "expected #{value} to be refused") do
        HotCell::Response.parse line
      end
      assert_match "must be true or false", error.message
    end
  end

  # Permanent is the answer that cannot be taken back, so a garbled flag must not be able to say it. The
  # code decides instead, which is what an older peer that never sent the field already gets.
  def test_a_permanent_flag_that_is_not_a_boolean_is_derived_rather_than_believed
    line = %({"v":1,"ok":false,"error":{"code":"capacity","permanent":"yes"}}\n)

    refute_predicate HotCell::Response.parse(line).failure, :permanent?
  end
end
