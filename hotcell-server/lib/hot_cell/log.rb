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

    # A log line is never worth the cell. This runs inside the loop that enforces every request's deadline,
    # and the sink is a pipe to a runtime that can go away or stop draining. Losing the line is the correct
    # trade against losing the process.
    def write(event, **fields)
      emit line(event, fields)
    rescue JSON::GeneratorError
      emit line(event, unloggable: fields.keys)
    end

    private
      # Never blocks. A closed reader is EPIPE and a full disk behind the driver is ENOSPC, both rescued —
      # but a reader that is alive and not draining is neither: a blocking write would simply park the
      # deadline loop until the runtime resumed. A non-blocking write answers `:wait_writable` for the full
      # pipe instead, and the line is dropped like any other.
      #
      # A short count would be a torn line, which a write at or under PIPE_BUF cannot produce. The one line
      # that can exceed it is cell.boot's inventory, written once before the loop enforces anything and
      # against an empty pipe.
      def emit(line)
        @io.write_nonblock line, exception: false
      rescue SystemCallError, IOError
        nil
      end

      def line(event, fields)
        JSON.generate({ at: Time.now.utc.iso8601(3), event: event }.merge(fields)) << "\n"
      end
  end
end
