# Accepting an explicit nil limit, which the supervisor then does arithmetic with.
require "hot_cell/server"
module HotCell
  class Configuration
    def initialize(**options)
      unknown = options.keys - SCHEDULING.keys - Limits::KEYS
      raise ConfigurationError, "unknown setting #{unknown.join(", ")}" if unknown.any?

      SCHEDULING.each { |key, default| instance_variable_set :"@#{key}", options.fetch(key, default) }
      @limits = Limits.new(**LIMITS.merge(options.slice(*Limits::KEYS)))
      send :verify!
    end
  end
end
