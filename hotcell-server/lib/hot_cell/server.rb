# frozen_string_literal: true

require "hot_cell/core"

require "hot_cell/server/version"
require "hot_cell/server/errors"
require "hot_cell/limits"
require "hot_cell/configuration"
require "hot_cell/registry"
require "hot_cell/operation"
require "hot_cell/slot"
require "hot_cell/log"
require "hot_cell/counters"
require "hot_cell/control"
require "hot_cell/worker"
require "hot_cell/supervisor"

module HotCell
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # A cell is configured once, and everything about scheduling lives here rather than on an operation.
    #
    #   HotCell.limits concurrency: 4, queue_factor: 2, deadline: 60, queue_wait: 10, reuse: 1,
    #                  memory: 1536 * 1024**2, file_size: 48 * 1024**2
    def limits(**options)
      return configuration if options.empty?

      @configuration = Configuration.new(**options)
    end

    # Test support.
    def reset!
      @configuration = nil
      Registry.clear
    end
  end
end
