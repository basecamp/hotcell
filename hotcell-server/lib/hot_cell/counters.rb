# frozen_string_literal: true

module HotCell
  # These live in the supervisor, and a forked worker can still report them: a child inherits the
  # supervisor's memory at fork, so the worker answering a metrics request reads a consistent snapshot of
  # counters it never had to be told. This is the one place fork-per-request is a convenience rather than
  # a cost.
  #
  # Three of these are not derivable on the client side, which is why the control channel exists at all.
  # queue_high_water is the leading saturation signal and no single caller sees it. killed_by separates a
  # decompression bomb from a slow afternoon in aggregate. cancelled counts callers that gave up before
  # the cell answered, which by definition appears on no response.
  class Counters
    def initialize
      @started_at = Clock.now
      @requests = Hash.new(0)
      @killed_by = Hash.new(0)
      @cancelled = 0
      @queue_high_water = 0
    end

    def record(code)
      @requests[:total] += 1
      @requests[(code || :ok).to_sym] += 1
    end

    def record_kill(limit)
      @killed_by[limit.to_sym] += 1
    end

    def cancelled!
      @cancelled += 1
    end

    def observe_queue(depth)
      @queue_high_water = depth if depth > @queue_high_water
    end

    def to_h(running: 0, queued: 0)
      { uptime_s: (Clock.now - @started_at).round, running: running, queued: queued,
        queue_high_water: @queue_high_water, requests: @requests, killed_by: @killed_by,
        cancelled: @cancelled }
    end
  end
end
