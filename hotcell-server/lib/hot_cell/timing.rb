# frozen_string_literal: true

module HotCell
  # One request's timing ledger, carried through the worker instead of the two loose values it replaces.
  #
  # It exists for the base instant rather than for tidiness. `perform_ms` means time spent performing where
  # performing happened, and time since the request arrived where it did not — a request refused for a
  # protocol mismatch never performed anything, so measuring it from the start is the only meaningful number.
  # That distinction used to live in the argument every caller passed: `refuse`'s `since` was `started` on
  # three paths and `began` on a fourth, and getting it wrong would have been invisible. The base moves once,
  # here, when `performing` is called.
  #
  # Phases accumulate as they complete, so a refusal reports the ones that finished before the failure. An
  # `unreadable` verdict that arrives with no `operation_ms` says exactly where it got to.
  class Timing
    attr_reader :queued_ms, :started

    def initialize(queued_ms)
      @queued_ms = queued_ms
      @started = Clock.now
      @base = @started
      @phases = {}
    end

    # Performing starts now, so this is what perform_ms measures from.
    def performing
      @base = Clock.now
    end

    def measure(phase)
      at = Clock.now
      result = yield
      @phases[phase] = Clock.ms_since(at)
      result
    end

    def to_h
      { queued_ms: queued_ms, **@phases, perform_ms: Clock.ms_since(@base) }
    end

    # The whole request as the cell saw it, including reading the message. For the log line rather
    # than for the caller, who is told what performing cost.
    def elapsed_ms
      Clock.ms_since started
    end
  end
end
