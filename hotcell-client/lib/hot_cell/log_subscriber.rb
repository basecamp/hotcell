# frozen_string_literal: true

require "json"

# All three, in this order, on Rails main: log_subscriber needs ColorizeLogging, which only the top-level file
# autoloads, and loading it before deprecation warns of a circular require.
require "active_support"
require "active_support/deprecation"
require "active_support/log_subscriber"

module HotCell
  # One line per call, success or failure, from the `perform.hot_cell` event. The railtie attaches it; an
  # application without Rails calls `HotCell::LogSubscriber.attach_to :hot_cell` and sets
  # `ActiveSupport::LogSubscriber.logger`.
  #
  # Two clocks on purpose: `perform_ms` is what the cell measured inside the worker and `duration_ms` is what
  # this process waited, and their difference is the queue and the socket.
  #
  # `stderr` is text a tool wrote while reading a hostile file. It goes into the JSON and nowhere else, so
  # its newlines arrive escaped rather than as forged log lines. `ascii_only` because JSON leaves U+2028 and
  # its kin raw, and a log viewer may break a line on them.
  class LogSubscriber < ActiveSupport::LogSubscriber
    def perform(event)
      payload = event.payload
      duration_ms = event.duration.round(1)

      info do
        "  HotCell (#{duration_ms}ms) " + JSON.generate({
          cell: payload[:cell],
          operation: payload[:operation],
          code: payload[:code],
          exception: payload[:exception]&.first,
          cause: payload[:cause],
          perform_ms: payload[:perform_ms],
          duration_ms: duration_ms,
          bytes_in: payload[:bytes_in],
          bytes_out: payload[:bytes_out],
          stderr: payload[:stderr],
        }.compact, ascii_only: true)
      end
    end
  end
end
