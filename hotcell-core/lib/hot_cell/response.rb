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
      include Fields

      def noun
        "response"
      end

      def ok(result: {}, timing: {})
        new result: result, timing: timing
      end

      def failed(failure, timing: {})
        new failure: failure, timing: timing
      end

      # `ok` has to be the boolean it says it is rather than anything truthy. This is the field the whole
      # taxonomy turns on, and Ruby's truthiness would read `"false"`, `0` and `[]` as success — so a
      # malformed or hostile response could turn a failure into an `ok` carrying no result at all.
      #
      # **Accepted risk.** Nothing inside `result` is checked, and a compromised cell chooses all of it.
      # `Payload.validate!` is not run on the way in, so a value JSON can carry but Ruby cannot serialize
      # again reaches the caller — `1e400` parses to `Float::INFINITY`, and an application that writes a
      # result to a JSON column raises there rather than here. The premise is that a result is data the
      # caller acts on and only the caller knows its shape, so the framework has no rule to apply and a
      # client with a specific expectation states it itself. `ok` is the exception because the taxonomy
      # turns on it and every caller depends on it equally.
      def parse(line)
        parse_message(line) do |parsed|
          ok = parsed[:ok]
          unless ok == true || ok == false
            raise MessageError, "response ok is #{ok.inspect} and must be true or false"
          end

          timing = parsed[:timing].is_a?(Hash) ? parsed[:timing] : {}

          if ok
            new version: parsed[:v], result: object(parsed, :result), timing: timing
          else
            new version: parsed[:v], failure: Failure.from_wire(object(parsed, :error)), timing: timing
          end
        end
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
