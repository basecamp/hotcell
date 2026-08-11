# frozen_string_literal: true

module HotCell
  # An operation name is namespaced, and the namespace is what stops two operation sets colliding on one
  # cell. Both sides derive the same default from the same rule, so a client and an operation that were
  # never written together still agree.
  #
  # A trailing Operation is stripped, because the naming convention puts it on the cell-side class and not
  # on the client — so TransformImage in the application and TransformImageOperation in the cell both
  # derive "transform_image", the way Rails strips Controller from a controller's route name.
  #
  # This runs in one direction only. A name that arrived on the wire is never turned back into a constant:
  # it is looked up in a registry that only ever holds classes the cell already loaded.
  module Naming
    class << self
      def default_operation_name(klass)
        if klass.name.nil?
          raise ConfigurationError, "#{klass.inspect} is anonymous, so it needs an explicit name"
        end

        *namespaces, base = klass.name.split("::")
        base = base.delete_suffix("Operation") unless base == "Operation"

        [ *namespaces, base ].map { |part| underscore(part) }.join(".")
      end

      def underscore(camel)
        camel.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
