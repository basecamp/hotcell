# frozen_string_literal: true

require "test_helper"

class PayloadTest < HotCellTest
  def test_symbol_keys_are_how_a_payload_is_naturally_written
    assert_equal '{"format":"png"}', HotCell::Payload.generate({ format: "png" }, "payload")
  end

  def test_string_keys_arrive_symbolized
    assert_equal({ format: "png" }, HotCell::Payload.parse('{"format":"png"}'))
  end

  def test_keys_are_symbolized_at_every_depth
    parsed = HotCell::Payload.parse('{"operations":{"resize_to_limit":[800,600]}}')

    assert_equal({ operations: { resize_to_limit: [ 800, 600 ] } }, parsed)
  end

  def test_values_are_not_symbolized
    assert_equal({ format: "png" }, HotCell::Payload.parse('{"format":"png"}'))
    assert_instance_of String, HotCell::Payload.parse('{"format":"png"}')[:format]
  end

  def test_a_symbol_value_raises_rather_than_serializing_to_something_that_does_not_return
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ format: :png }, "payload")
    end

    assert_match "payload[:format] is a Symbol", error.message
  end

  def test_a_time_value_raises
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ at: Time.now }, "payload")
    end

    assert_match "payload[:at] is a Time", error.message
  end

  def test_a_custom_object_value_raises
    custom = Class.new do
      def to_json(*) = '"looks fine"'
    end

    assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ thing: custom.new }, "payload")
    end
  end

  def test_the_message_names_the_path_to_the_offending_value
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ operations: { resize: [ 800, :fill ] } }, "payload")
    end

    assert_match "payload[:operations][:resize][1] is a Symbol", error.message
  end

  def test_a_non_string_key_raises
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ 1 => "one" }, "payload")
    end

    assert_match "payload has a Integer key 1", error.message
  end

  def test_a_payload_that_is_not_an_object_raises
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate([ 1, 2 ], "payload")
    end

    assert_match "payload is a Array and must be a Hash", error.message
  end

  def test_an_infinite_float_raises
    assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ ratio: Float::INFINITY }, "payload")
    end
  end

  def test_a_nan_float_raises
    assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ ratio: Float::NAN }, "payload")
    end
  end

  # JSON.generate refuses these, and it refuses them *after* validation has said the structure is fine. In a
  # worker that meant dying with no answer at all, on a response that had already been decided — so the caller
  # read a closed socket and retried something that would fail the same way forever. Tools produce these:
  # a filename, or a line of stderr.
  def test_a_string_whose_bytes_are_not_valid_utf8_is_refused_here_rather_than_by_the_generator
    invalid = { note: "caf\xFF".dup.force_encoding(Encoding::UTF_8) }

    error = assert_raises(HotCell::SerializationError) { HotCell::Payload.generate(invalid, "result") }
    assert_match "result[:note] is a String whose bytes are not valid UTF-8", error.message

    # The premise: without the check, this is where it would have blown up instead.
    assert_raises(JSON::GeneratorError) { JSON.generate(invalid) }
  end

  def test_an_invalid_string_nested_anywhere_is_refused
    assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ lines: [ "fine", "bad \xC3".dup.force_encoding(Encoding::UTF_8) ] }, "result")
    end
  end

  def test_json_native_values_pass
    payload = { string: "s", integer: 1, float: 1.5, yes: true, no: false, nothing: nil,
                list: [ 1, "two", nil ], nested: { deeper: true } }

    assert_equal payload, HotCell::Payload.parse(HotCell::Payload.generate(payload, "payload"))
  end

  def test_nesting_past_the_limit_raises_rather_than_recursing
    deep = (1..HotCell::Payload::MAX_DEPTH + 1).inject("leaf") { |inner, _| { down: inner } }

    assert_raises HotCell::SerializationError do
      HotCell::Payload.generate(deep, "payload")
    end
  end

  def test_nesting_at_the_limit_passes
    deep = (1...HotCell::Payload::MAX_DEPTH).inject("leaf") { |inner, _| { down: inner } }

    assert_equal deep, HotCell::Payload.parse(HotCell::Payload.generate(deep, "payload"))
  end

  def test_parsing_past_the_nesting_limit_raises
    deep = (1..HotCell::MAX_NESTING + 1).inject('"leaf"') { |inner, _| "{\"down\":#{inner}}" }

    assert_raises JSON::NestingError do
      HotCell::Payload.parse(deep)
    end
  end

  # JSON.load and create_additions instantiate whatever class a json_class key names. Neither is used
  # here, and a document that asks for one gets an ordinary Hash.
  def test_a_json_class_key_instantiates_nothing
    parsed = HotCell::Payload.parse('{"json_class":"Time","s":0,"n":0}')

    assert_instance_of Hash, parsed
    assert_equal "Time", parsed[:json_class]
  end

  def test_parsing_nan_raises_rather_than_producing_a_float_that_breaks_arithmetic
    assert_raises JSON::ParserError do
      HotCell::Payload.parse('{"ratio":NaN}')
    end
  end

  def test_the_name_appears_in_the_message_so_a_result_does_not_read_as_a_payload
    error = assert_raises HotCell::SerializationError do
      HotCell::Payload.generate({ width: :wide }, "result")
    end

    assert_match "result[:width] is a Symbol", error.message
  end

  # Legal Ruby, two keys, and one JSON key space. `{"a":1,"a":2}` parses back as one pair, so a value
  # disappears with nothing to say so — and this runs on results, where that would be the caller's data.
  def test_a_hash_holding_both_a_symbol_and_a_string_of_one_name_is_refused
    error = assert_raises(HotCell::SerializationError) do
      HotCell::Payload.validate!({ a: 1, "a" => 2 }, "payload")
    end

    assert_match "which are one key in JSON", error.message
  end

  def test_the_same_name_at_different_depths_is_fine
    assert HotCell::Payload.validate!({ a: { "a" => 1 } }, "payload")
    assert HotCell::Payload.validate!({ a: 1, b: 2, "c" => 3 }, "payload")
  end
end
