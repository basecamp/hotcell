# frozen_string_literal: true

require "json"

module HotCell
  # A payload is a JSON object, and the rules are stricter than JSON's in one direction and looser in
  # another.
  #
  # Values must be JSON-native, because to_json is not a check. It serializes a Symbol to a String, a
  # Time to a String, and an arbitrary object through whatever to_json that object happens to define,
  # all silently and none of it faithfully. So validate the values, then serialize.
  #
  # Keys may be Strings or Symbols, because both serialize to the same JSON string and both arrive
  # symbolized. `{ format: "png" }` is how a payload is naturally written and must not be rejected.
  module Payload
    # A payload sits one level inside the message envelope, so it gets one level less than the line.
    MAX_DEPTH = MAX_NESTING - 1

    class << self
      def generate(object, name)
        validate! object, name
        JSON.generate object
      end

      # Keys are symbolized so operations read payload[:format] and can splat a nested hash into keyword
      # arguments. Values are not: a Symbol would not survive the round trip, which the JSON-native rule
      # already forbids.
      #
      # One rescue for the whole JSON layer. Naming what JSON.parse raises has been wrong twice: a report
      # that was not an object raised TypeError past a rescue for JSON::ParserError, and a key holding
      # invalid UTF-8 raised EncodingError past both. The supervisor parses worker reports inside its
      # deadline loop with nothing above it rescuing, so each miss denies service to every request in the
      # cell.
      #
      # The body is one JSON.parse call, so the rescue cannot hide a bug of our own. NoMemoryError is not
      # a StandardError and stays uncaught: a document that large is the worker's memory verdict, not a
      # bad line.
      def parse(json)
        JSON.parse json, symbolize_names: true, max_nesting: MAX_NESTING, allow_nan: false
      rescue StandardError => error
        raise MessageError, "#{error.class}: #{Failure.sanitize(error.message)}"
      end

      def validate!(object, name)
        unless object.is_a?(Hash)
          raise SerializationError, "#{name} is a #{object.class} and must be a Hash"
        end

        walk object, name, 1
        object
      end

      private
        def walk(value, path, depth)
          case value
          when Hash
            too_deep! path, depth
            seen = {}

            value.each do |key, nested|
              unless key.is_a?(String) || key.is_a?(Symbol)
                raise SerializationError,
                      "#{path} has a #{key.class} key #{key.inspect}; keys must be String or Symbol"
              end

              # A Hash holding both :a and "a" is legal Ruby and two distinct keys. JSON has one string key
              # space, so it serializes to a document with "a" twice, and parsing that back keeps whichever
              # came last — one of the values is gone and nothing said so. Refused here rather than silently
              # dropped, because this runs on results too, where the loss would be the caller's data.
              if (clash = seen[key.to_s])
                raise SerializationError,
                      "#{path} has both #{clash.inspect} and #{key.inspect}, which are one key in JSON"
              end
              seen[key.to_s] = key

              walk nested, "#{path}[#{key.inspect}]", depth + 1
            end
          when Array
            too_deep! path, depth
            value.each_with_index { |nested, index| walk nested, "#{path}[#{index}]", depth + 1 }
          when Float
            unless value.finite?
              raise SerializationError, "#{path} is #{value}, which JSON cannot carry"
            end
          when String
            # JSON.generate refuses a String whose bytes are not valid UTF-8, and it refuses it *after* this
            # has said the structure is fine. In a worker that meant dying with no answer at all, on a
            # response that had already been decided — so the caller read a closed socket and retried
            # something that will fail the same way every time. Tools produce these: a filename, or a
            # line of stderr. Scrub it in the operation if you want it; it is not scrubbed here, because a
            # result is data the caller acts on rather than a diagnostic.
            unless value.valid_encoding?
              raise SerializationError, "#{path} is a String whose bytes are not valid #{value.encoding}"
            end

            value
          when Integer, true, false, nil
            value
          else
            raise SerializationError, "#{path} is a #{value.class}, which JSON cannot carry faithfully"
          end
        end

        def too_deep!(path, depth)
          return if depth <= MAX_DEPTH
          raise SerializationError, "#{path} nests deeper than #{MAX_DEPTH} levels"
        end
    end
  end
end
