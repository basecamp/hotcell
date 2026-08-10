# frozen_string_literal: true

module HotCell
  # How a class-level declaration is read back on both sides of the socket.
  #
  # `HotCell::Client` and `HotCell::Operation` are the same shape of thing — a class whose body declares what
  # it is, with a subclass free to override one declaration and inherit the rest. Both needed the same lookup
  # and both had their own copy of it, in gems that are never loaded together and so could never diverge
  # loudly. This is the shared home they already have.
  #
  # A class-level instance variable is not visible to a subclass, which is what makes `@stage` on a base class
  # invisible to the operation that inherits from it. Walking `ancestors` is what turns that into inheritance.
  # `Class` only, because a module cannot carry one of these declarations.
  module Declarations
    private
      # The first ancestor that set it, or nil. `false` is a value and survives; only nil means unset.
      def inherited_value(variable)
        ancestors.grep(Class).each do |ancestor|
          value = ancestor.instance_variable_get(variable)
          return value unless value.nil?
        end

        nil
      end
  end
end
