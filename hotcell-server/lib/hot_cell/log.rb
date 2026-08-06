# frozen_string_literal: true

require "json"
require "time"

module HotCell
  # A cell has no network, so nothing inside it can dial a collector. That rules out less than it appears
  # to, because stdout is not a network: it is a pipe to the container runtime, whose log driver runs in
  # that daemon with the host's network. So logs ship normally under network: none, and a cell writes
  # structured JSON lines with the standard library and gets a real log for free.
  #
  # This is the channel for everything no response can carry: deadline kills, reaps that found a signal,
  # boot checks, and queue high-water.
  class Log
    def self.null
      new File.open(File::NULL, "w")
    end

    def initialize(io = $stdout)
      @io = io
      @io.sync = true
    end

    def write(event, **fields)
      @io.write line(event, fields)
    rescue JSON::GeneratorError
      @io.write line(event, unloggable: fields.keys)
    end

    private
      def line(event, fields)
        JSON.generate({ at: Time.now.utc.iso8601(3), event: event }.merge(fields)) << "\n"
      end
  end
end
