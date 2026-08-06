# frozen_string_literal: true

require "test_helper"

class RequestTest < HotCellTest
  def test_a_request_round_trips
    request = HotCell::Request.new(op: "test.echo", inputs: 1, outputs: 1, payload: { format: "png" })
    parsed = HotCell::Request.parse(request.to_line)

    assert_equal "test.echo", parsed.op
    assert_equal 1, parsed.inputs
    assert_equal 1, parsed.outputs
    assert_equal({ format: "png" }, parsed.payload)
    assert_equal HotCell::PROTOCOL_VERSION, parsed.version
  end

  def test_a_request_line_ends_with_a_newline
    assert_end_with "\n", HotCell::Request.new(op: "test.echo").to_line
  end

  def test_descriptor_count_is_the_two_counts_added
    assert_equal 3, HotCell::Request.new(op: "test.echo", inputs: 2, outputs: 1).descriptor_count
  end

  def test_a_request_over_the_byte_limit_raises_rather_than_being_sent
    request = HotCell::Request.new(op: "test.big", payload: { blob: "x" * HotCell::MAX_REQUEST_BYTES })

    error = assert_raises(HotCell::MessageError) { request.to_line }
    assert_match "over the #{HotCell::MAX_REQUEST_BYTES} byte limit", error.message
  end

  def test_a_payload_value_json_cannot_carry_raises_before_the_line_is_built
    request = HotCell::Request.new(op: "test.echo", payload: { format: :png })

    assert_raises(HotCell::SerializationError) { request.to_line }
  end

  def test_more_descriptors_than_the_protocol_carries_raises
    error = assert_raises HotCell::MessageError do
      HotCell::Request.new(op: "test.echo", inputs: HotCell::MAX_DESCRIPTORS, outputs: 1)
    end

    assert_match "over the #{HotCell::MAX_DESCRIPTORS} limit", error.message
  end

  # A version mismatch is transient and arrives at one hundred percent, so the receiver has to be able
  # to read the line far enough to say so.
  def test_parsing_keeps_a_foreign_version_so_the_receiver_can_answer_protocol
    parsed = HotCell::Request.parse('{"v":99,"op":"test.echo","inputs":0,"outputs":0,"payload":{}}')

    assert_equal 99, parsed.version
    refute_predicate parsed, :current_version?
  end

  def test_the_current_version_says_so
    assert_predicate HotCell::Request.new(op: "test.echo"), :current_version?
  end

  def test_parsing_something_that_is_not_json
    assert_raises(HotCell::MessageError) { HotCell::Request.parse("not json at all\n") }
  end

  def test_parsing_something_that_is_not_an_object
    assert_raises(HotCell::MessageError) { HotCell::Request.parse("[1,2,3]\n") }
  end

  def test_parsing_a_request_with_no_op
    error = assert_raises HotCell::MessageError do
      HotCell::Request.parse('{"v":1,"inputs":0,"outputs":0,"payload":{}}')
    end

    assert_match "request op is nil", error.message
  end

  def test_parsing_a_request_with_an_empty_op
    assert_raises HotCell::MessageError do
      HotCell::Request.parse('{"v":1,"op":"","inputs":0,"outputs":0,"payload":{}}')
    end
  end

  def test_parsing_a_request_with_a_negative_count
    error = assert_raises HotCell::MessageError do
      HotCell::Request.parse('{"v":1,"op":"test.echo","inputs":-1,"outputs":0,"payload":{}}')
    end

    assert_match "must not be negative", error.message
  end

  def test_parsing_a_request_whose_count_is_not_an_integer
    assert_raises HotCell::MessageError do
      HotCell::Request.parse('{"v":1,"op":"test.echo","inputs":"1","outputs":0,"payload":{}}')
    end
  end

  def test_parsing_a_request_whose_payload_is_not_an_object
    error = assert_raises HotCell::MessageError do
      HotCell::Request.parse('{"v":1,"op":"test.echo","inputs":0,"outputs":0,"payload":[]}')
    end

    assert_match "must be a JSON object", error.message
  end

  private
    def assert_end_with(suffix, string)
      assert string.end_with?(suffix), "expected #{string.inspect} to end with #{suffix.inspect}"
    end
end
