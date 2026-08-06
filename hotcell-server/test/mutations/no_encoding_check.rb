# Letting a String whose bytes are not valid UTF-8 through validation, so JSON.generate refuses it later and
# the worker dies with no answer on a response it had already decided.
require "hot_cell/server"
module HotCell
  module Payload
    class << self
      private def walk(value, path, depth)
        case value
        when Hash
          too_deep! path, depth
          value.each do |key, nested|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise SerializationError, "#{path} has a #{key.class} key #{key.inspect}"
            end
            walk nested, "#{path}[#{key.inspect}]", depth + 1
          end
        when Array
          too_deep! path, depth
          value.each_with_index { |nested, index| walk nested, "#{path}[#{index}]", depth + 1 }
        when Float
          raise SerializationError, "#{path} is #{value}" unless value.finite?
        when String, Integer, true, false, nil
          value
        else
          raise SerializationError, "#{path} is a #{value.class}"
        end
      end
    end
  end
end
