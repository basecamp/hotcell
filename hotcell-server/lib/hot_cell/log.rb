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
  #
  # Lines follow docs/LOGS.md: ECS field names, domain fields under the hotcell namespace. The fleet's
  # collector routes on service.name, takes the record timestamp from @timestamp, and severity from
  # log.level, so those three are load-bearing: renaming any of them silently drops or mislabels every
  # cell log line in production.
  class Log
    # Severity lives here rather than in the collector so that adding an event never needs a collector
    # change. An event missing from this table logs as INFO rather than not at all.
    LEVELS = {
      "cell.boot" => "INFO",
      "cell.stopping" => "INFO",
      "cell.stopped" => "INFO",
      "cell.ptrace_scope_unknown" => "ERROR",
      "request" => "INFO",
      "request.abandoned" => "WARN",
      "worker.forked" => "INFO",
      "worker.reaped" => "INFO",
      "worker.crashed" => "ERROR",
      "worker.killed" => "WARN",
      "worker.deadline" => "WARN",
      "worker.lingered" => "WARN",
      "worker.unforkable" => "ERROR",
      "worker.undispatchable" => "ERROR",
      "worker.unreadable_report" => "ERROR",
      "control.abandoned" => "WARN",
      "control.unanswerable" => "WARN",
      "slot.uncleaned" => "WARN",
      "slot.undiscarded" => "WARN",
    }.freeze

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
      # A short count would be a torn line, which a write at or under PIPE_BUF cannot produce. Torn is worse
      # than dropped: the stub ends without a newline, nothing retries the rest, and the next line any
      # process writes is glued to it — so a reader splitting on newlines gets one unparseable record where
      # there were two, and loses an innocent line along with the one that tore.
      #
      # Two lines can exceed it. cell.boot's inventory is written once before the loop enforces anything and
      # against an empty pipe. worker.killed is the other, and it is the one to watch: 512 bytes of a
      # worker's stderr become 3072 if every one of them is a control character, which leaves a few hundred
      # bytes of headroom that the operation name and the envelope spend. Reachable only by an operation
      # whose name runs to hundreds of bytes, so it is measured rather than seen — but it is measured
      # against a bound nothing enforces.
      def emit(line)
        @io.write_nonblock line, exception: false
      rescue SystemCallError, IOError
        nil
      end

      def line(event, fields)
        JSON.generate(document(event, fields.dup)) << "\n"
      end

      def document(event, fields)
        {
          "@timestamp": Time.now.utc.iso8601(3),
          service: { name: "hotcell" },
          event: event_fields(event, fields),
          log: { level: LEVELS.fetch(event, "INFO") },
          **process_fields(fields),
          **prose_fields(fields),
          **({ hotcell: fields } unless fields.empty?).to_h,
        }
      end

      def event_fields(event, fields)
        { action: event }.tap do |result|
          result[:outcome] = fields.delete(:outcome) if fields.key?(:outcome)
          result[:duration] = { ms: fields.delete(:duration_ms) } if fields.key?(:duration_ms)
        end
      end

      def process_fields(fields)
        process = {
          pid: fields.delete(:pid),
          exit_code: fields.delete(:exit_code),
        }.compact

        process.empty? ? {} : { process: process }
      end

      # `message` beside an exception is that exception's message; alone it is the line's prose.
      def prose_fields(fields)
        if fields.key?(:error)
          { error: { type: fields.delete(:error), message: fields.delete(:message) }.compact }
        elsif fields.key?(:message)
          { message: fields.delete(:message) }
        else
          {}
        end
      end
  end
end
