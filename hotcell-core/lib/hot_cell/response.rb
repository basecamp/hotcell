# frozen_string_literal: true

module HotCell
  # One line of JSON. Outputs are posted and flushed before success is reported, so the cold side may
  # read as soon as it sees `ok`.
  #
  # `timing` is present on every response, success or failure, and it is also the cell's tracing
  # channel. A cell cannot reach a trace collector, so anything it knows about its own internals
  # travels back here or not at all. An operation may add its own keys, and a client should treat the
  # map as open.
  class Response
    attr_reader :version, :result, :failure, :timing

    class << self
      def ok(result: {}, timing: {})
        new result: result, timing: timing
      end

      def failed(failure, timing: {})
        new failure: failure, timing: timing
      end

      def parse(line)
        parsed = Payload.parse(line)
        raise MessageError, "response is not a JSON object" unless parsed.is_a?(Hash)

        timing = parsed[:timing].is_a?(Hash) ? parsed[:timing] : {}

        if parsed[:ok]
          new version: parsed[:v], result: object(parsed, :result), timing: timing
        else
          new version: parsed[:v], failure: Failure.from_wire(object(parsed, :error)), timing: timing
        end
      rescue JSON::ParserError => error
        raise MessageError, "response is not valid JSON: #{error.message}"
      end

      private
        def object(parsed, key)
          value = parsed[key]
          return value if value.is_a?(Hash)

          raise MessageError, "response #{key} is #{value.inspect} and must be a JSON object"
        end
    end

    def initialize(result: nil, failure: nil, timing: {}, version: PROTOCOL_VERSION)
      @result = result
      @failure = failure
      @timing = timing
      @version = version
    end

    def ok?
      failure.nil?
    end

    def to_line
      body = { v: version, ok: ok? }
      if ok?
        body[:result] = Payload.validate!(result, "result")
      else
        body[:error] = failure.to_h
      end
      body[:timing] = Payload.validate!(timing, "timing")

      line = JSON.generate(body) << "\n"
      if line.bytesize > MAX_RESPONSE_BYTES
        raise MessageError, "response is #{line.bytesize} bytes, over the #{MAX_RESPONSE_BYTES} byte limit"
      end

      line
    end
  end
end
