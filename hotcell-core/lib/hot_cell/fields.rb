# frozen_string_literal: true

module HotCell
  # How a wire message reads its own fields, shared by Request and Response.
  #
  # The two had a copy each of the same parse preamble and the same typed-field check, differing only in
  # whether the error said "request" or "response" — so a fix to the wording landed in one and not the other.
  #
  # The includer states its own `noun`. Deriving it from the class name looks tidier and does not work:
  # Request's singleton defines `name(parsed, key)` for its own String field, which shadows Module#name.
  module Fields
    private
      # Wraps the two errors every parse can produce: a line that is not JSON, and a line that is JSON but
      # not an object. The block builds the message from the parsed Hash.
      def parse_message(line)
        parsed = Payload.parse(line)
        raise MessageError, "#{noun} is not a JSON object" unless parsed.is_a?(Hash)

        yield parsed
      rescue JSON::ParserError => error
        raise MessageError, "#{noun} is not valid JSON: #{error.message}"
      end

      def object(parsed, key)
        value = parsed[key]
        return value if value.is_a?(Hash)

        raise MessageError, "#{noun} #{key} is #{value.inspect} and must be a JSON object"
      end
  end
end
