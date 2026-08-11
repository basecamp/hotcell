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
require "hot_cell/timing"
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
    #   HotCell.limits concurrency: 4, queue_size: 8, deadline: 60, queue_wait: 10, max_requests_per_worker: 1,
    #                  memory: 1536 * 1024**2, file_size: 48 * 1024**2
    def limits(**options)
      return configuration if options.empty?

      @configuration = Configuration.new(**options)
    end

    # Boots a cell's code: the configuration file first, explicitly, then every operation file in sorted
    # order. A derived image adds these by copying files in, never by changing this gem, and a cell with
    # no config.rb takes every default.
    def load!(config: ENV.fetch("HOTCELL_CONFIG", "/hotcell/config.rb"),
              operations: ENV.fetch("HOTCELL_OPERATIONS", "/hotcell/operations"))
      require config if File.exist?(config)

      Dir.glob(File.join(operations, "**", "*.rb")).sort.each { |file| require file }
    end
  end
end
