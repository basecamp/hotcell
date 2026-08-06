# frozen_string_literal: true

module HotCell
  # An operation name is namespaced, and the namespace is what stops two operation sets colliding on one
  # cell. Both sides derive the same default from the same rule, so a client and an operation that were
  # never written together still agree.
  #
  # This runs in one direction only. A wire name is never turned back into a constant: it is looked up in a
  # registry that only ever holds classes the cell already loaded.
  module Naming
    class << self
      def default_operation_name(klass)
        if klass.name.nil?
          raise ConfigurationError, "#{klass.inspect} is anonymous, so it needs an explicit name"
        end

        klass.name.split("::").map { |part| underscore(part) }.join(".")
      end

      def underscore(camel)
        camel.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
