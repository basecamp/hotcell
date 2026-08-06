# frozen_string_literal: true

module HotCell
  # Monotonic, because every duration here is reported to a caller that will alarm on it, and a clock
  # that can step backwards produces negative latencies during an NTP correction.
  module Clock
    class << self
      def now
        Process.clock_gettime Process::CLOCK_MONOTONIC
      end

      def ms_since(at)
        ((now - at) * 1000).round(2)
      end
    end
  end
end
