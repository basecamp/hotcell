# frozen_string_literal: true

require "active_support"
require "hot_cell/client"
require "yabeda"

require "yabeda/hot_cell/version"

module Yabeda
  # A cell's control socket is host-local, and the collect block runs in every scraped process on every host,
  # which matches that topology exactly.
  #
  # Two namespace traps here, both silent. Inside `module Yabeda`, `HotCell` resolves to this module, so the
  # client must be named ::HotCell. And `hotcell` is a DSL method that exists only inside Yabeda.configure, so
  # anything factored out of the collect block must say Yabeda.hotcell.
  module HotCell
    def self.install!
      Yabeda.configure do
        group :hotcell

        counter :requests, comment: "Calls through perform_in_hotcell, by outcome",
          tags: %i[ cell operation code cause ]
        histogram :perform, comment: "Time the cell spent performing", unit: :seconds,
          tags: %i[ cell operation ], buckets: [ 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 120 ]

        gauge :up, comment: "1 when the local cell answers its control socket",
          tags: %i[ cell ], aggregation: :most_recent
        gauge :running, comment: "Workers busy right now", tags: %i[ cell ], aggregation: :most_recent
        gauge :queued, comment: "Connections waiting for a worker", tags: %i[ cell ], aggregation: :most_recent
        gauge :queue_high_water, comment: "Deepest the queue has been since boot",
          tags: %i[ cell ], aggregation: :most_recent
        gauge :cancelled, comment: "Callers that gave up before the cell answered (a floor)",
          tags: %i[ cell ], aggregation: :most_recent
        gauge :killed, comment: "Workers killed since boot, by cause",
          tags: %i[ cell cause ], aggregation: :most_recent
        gauge :uptime_seconds, comment: "Seconds since the supervisor booted",
          tags: %i[ cell ], aggregation: :most_recent

        collect { Yabeda::HotCell.collect_stats }
      end

      subscribe_to_performs
    end

    def self.collect_stats
      ::HotCell.cells.each_value do |cell|
        next unless cell.enabled?

        response = cell.metrics
        Yabeda.hotcell.up.set({ cell: cell.name }, response&.ok? ? 1 : 0)
        next unless response&.ok?

        set_counters cell, response.result
      end
    rescue => error
      # A scrape must not fail because a cell is misbehaving. In a Rails application this is Rails.error.
      ::ActiveSupport.error_reporter.report error, handled: true
    end

    # The subscriber raises into whoever called instrument, so an unguarded bug here would arrive as a failed
    # call rather than as missing metrics.
    def self.subscribe_to_performs
      ::ActiveSupport::Notifications.subscribe "perform.hot_cell" do |event|
        record_perform event
      rescue => error
        ::ActiveSupport.error_reporter.report error, handled: true
      end
    end

    # A failed call is not reported from here: the raise the caller sees already reaches the error reporter.
    #
    # An exception that escapes the call, such as the application's own request timeout, leaves no code on the
    # event, and the cell measured nothing.
    def self.record_perform(event)
      labels = { cell: event.payload[:cell], operation: event.payload[:operation] }
      code = event.payload[:code] || (event.payload[:exception] ? "exception" : "ok")

      # Empty rather than absent, because a label that is sometimes missing is a separate series in Prometheus
      # and a query by code would silently split.
      Yabeda.hotcell.requests.increment(labels.merge(code: code, cause: event.payload[:cause].to_s))
      Yabeda.hotcell.perform.measure(labels, (event.payload[:perform_ms] || 0) / 1000.0) unless code == "exception"
    end

    private_class_method def self.set_counters(cell, counters)
      tags = { cell: cell.name }

      Yabeda.hotcell.running.set(tags, counters[:running])
      Yabeda.hotcell.queued.set(tags, counters[:queued])
      Yabeda.hotcell.queue_high_water.set(tags, counters[:queue_high_water])
      Yabeda.hotcell.cancelled.set(tags, counters[:cancelled])
      Yabeda.hotcell.uptime_seconds.set(tags, counters[:uptime_s])
      ::HotCell::Codes::PERMANENT_BY_CAUSE.each_key do |cause|
        Yabeda.hotcell.killed.set(tags.merge(cause: cause), counters[:killed_by].fetch(cause.to_sym, 0))
      end
    end
  end
end
