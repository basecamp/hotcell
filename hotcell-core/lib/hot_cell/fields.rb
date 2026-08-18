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
      #
      # Payload.parse already answers with MessageError however the JSON layer failed, so this only adds
      # the noun. It rescues around that call alone rather than around the block, because the block's own
      # field checks raise MessageError too and re-wording those as "not valid JSON" would be a lie.
      def parse_message(line)
        parsed = begin
          Payload.parse(line)
        rescue MessageError => error
          raise MessageError, "#{noun} is not valid JSON: #{error.message}"
        end

        raise MessageError, "#{noun} is not a JSON object" unless parsed.is_a?(Hash)

        yield parsed
      end

      def object(parsed, key)
        value = parsed[key]
        return value if value.is_a?(Hash)

        raise MessageError, "#{noun} #{key} is #{value.inspect} and must be a JSON object"
      end
  end
end
