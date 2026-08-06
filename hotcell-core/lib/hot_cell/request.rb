# frozen_string_literal: true

module HotCell
  # One line of UTF-8 JSON terminated by a newline, sent with a single sendmsg carrying one SCM_RIGHTS
  # message.
  #
  #   {"v":1,"op":"active_storage.transform_image","inputs":1,"outputs":1,"payload":{"format":"png"}}
  #
  # Inputs are the leading descriptors and outputs the trailing ones, so two counts are the whole
  # framing and there is no naming layer to keep in step with an operation.
  class Request
    attr_reader :version, :op, :inputs, :outputs, :payload

    def initialize(op:, inputs: 0, outputs: 0, payload: {}, version: PROTOCOL_VERSION)
      @version = version
      @op = op
      @inputs = inputs
      @outputs = outputs
      @payload = payload

      verify_descriptor_count!
    end

    def descriptor_count
      inputs + outputs
    end

    def current_version?
      version == PROTOCOL_VERSION
    end

    def to_line
      Payload.validate! payload, "payload"

      line = JSON.generate({ v: version, op: op, inputs: inputs, outputs: outputs, payload: payload }) << "\n"
      if line.bytesize > MAX_REQUEST_BYTES
        raise MessageError, "request is #{line.bytesize} bytes, over the #{MAX_REQUEST_BYTES} byte limit"
      end

      line
    end

    class << self
      def parse(line)
        parsed = Payload.parse(line)
        raise MessageError, "request is not a JSON object" unless parsed.is_a?(Hash)

        new version: integer(parsed, :v), op: name(parsed, :op), inputs: count(parsed, :inputs),
            outputs: count(parsed, :outputs), payload: object(parsed, :payload)
      rescue JSON::ParserError => error
        raise MessageError, "request is not valid JSON: #{error.message}"
      end

      private
        def integer(parsed, key)
          value = parsed[key]
          return value if value.is_a?(Integer)

          raise MessageError, "request #{key} is #{value.inspect} and must be an Integer"
        end

        def count(parsed, key)
          integer(parsed, key).tap do |value|
            raise MessageError, "request #{key} is #{value} and must not be negative" if value.negative?
          end
        end

        def name(parsed, key)
          value = parsed[key]
          return value if value.is_a?(String) && !value.empty?

          raise MessageError, "request #{key} is #{value.inspect} and must be a non-empty String"
        end

        def object(parsed, key)
          value = parsed[key]
          return value if value.is_a?(Hash)

          raise MessageError, "request #{key} is #{value.inspect} and must be a JSON object"
        end
    end

    private
      def verify_descriptor_count!
        if descriptor_count > MAX_DESCRIPTORS
          raise MessageError, "request wants #{descriptor_count} descriptors, over the #{MAX_DESCRIPTORS} limit"
        end
      end
  end
end
