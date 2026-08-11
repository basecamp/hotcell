# frozen_string_literal: true

module HotCell
  # The `op` field on the wire is looked up here. A name that arrived on the wire is never used to derive a constant, so the
  # index only ever holds classes this cell already loaded.
  module Registry
    class << self
      def register(operation)
        operations << operation unless operations.include?(operation)
        reload!
        operation
      end

      def operations
        @operations ||= []
      end

      def names
        index.keys.sort
      end

      def lookup(name)
        index[name]
      end

      def reload!
        @index = nil
      end

      def clear
        @operations = []
        reload!
      end

      private
        def index
          @index ||= operations.each_with_object({}) do |operation, names|
            next if operation.abstract_operation?

            name = operation.operation_name

            if (claimed = names[name])
              raise ConfigurationError, "#{operation} and #{claimed} both answer to #{name.inspect}"
            end

            names[name] = operation
          end
        end
    end
  end
end
