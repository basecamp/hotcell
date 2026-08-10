# frozen_string_literal: true

module HotCell
  # Every failure carries a code and a `terminal` flag, and `terminal` is the only distinction that
  # changes what a caller must do.
  #
  # Terminal means the same request fails the same way until the input or the code changes — not until
  # the load or the deployment changes. A terminal failure may be recorded against a blob and served
  # from a cache. A non-terminal one must be retried and must never be written down.
  #
  # The flag travels on the wire, set by the side that knows, rather than being derived by each caller
  # from the code. That is what makes a code added later safe: an old client will not recognise it but
  # will still dispose of it correctly.
  module Codes
    TERMINAL = {
      "unreadable"  => true,   # the input could not be decoded
      "failed"      => true,   # the operation raised for some other reason
      "invalid"     => true,   # malformed request, or a descriptor that failed its access-mode check
      "unsupported" => false,  # this cell does not carry that operation — see below
      "protocol"    => false,  # version mismatch, which heals when the accessory reboots
      "capacity"    => false,  # the queue is full
      "unavailable" => false,  # no connection, or a connection closed with no response
      "timeout"     => false,  # the client's own deadline fired
    }.freeze

    # **`unsupported` is transient, and the design document says otherwise.** Its reasoning was that an
    # unknown *operation* is a caller bug that never heals, where an unknown *version* is a deploy window
    # that does. That holds for a typo and not for the case that actually happens: an accessory is not
    # updated by a deploy, so an application that ships a client for a new operation before anybody reboots
    # the cell gets `unsupported` at one hundred percent for as long as that takes.
    #
    # The two mistakes are not symmetrical. Retrying a caller's typo costs some work and shows up in the
    # `unsupported` rate and in the client's boot-time warning. Recording a deploy window as permanent
    # condemns every blob uploaded during it, and needs a hand-written backfill to undo.

    # `killed` splits on what the worker hit, because a caller cannot otherwise tell a decompression
    # bomb from a slow afternoon. Size and memory are properties of the input, so the same bytes will
    # do it again on an idle cell. A deadline is as much a property of the load, and treating it as
    # terminal means a busy hour permanently condemns whatever was uploaded during it.
    # `crashed` is the cell's own fault rather than the input's — a worker that died without answering, which
    # a misconfigured cell does on every request. Recording that against a blob would condemn everything
    # uploaded during a broken deploy, so it is transient. An older client that has never heard of it still
    # disposes of it correctly, because `terminal` travels on the wire.
    #
    # **A limit this table has never heard of is not terminal, and that default is the point of the table.**
    # A cell mints these; adding a kill reason to the supervisor without adding a row here used to make it
    # permanent, silently, and permanent is the answer that cannot be taken back. The names below are
    # constants so that the two places that mint them cannot spell one the table does not carry.
    #
    # Raising instead — the way an unknown *code* raises — would be worse than the bug. `Supervisor#answer_for`
    # builds its Failure as an argument to `answer`, so the raise would land before that method's rescue, and
    # neither `reap` nor `drain_signals` nor `run` catches it. A typo would take the whole cell down from the
    # one path whose job is reporting a dead worker.
    FSIZE = "fsize"
    MEMORY = "memory"
    DEADLINE = "deadline"
    SIGNAL = "signal"
    CRASHED = "crashed"

    TERMINAL_BY_LIMIT = {
      FSIZE    => true,
      MEMORY   => true,
      DEADLINE => false,
      SIGNAL   => true,
      CRASHED  => false,
    }.freeze

    KILLED = "killed"

    class << self
      def terminal?(code, limit: nil)
        code = code.to_s
        return TERMINAL_BY_LIMIT.fetch(limit.to_s, false) if code == KILLED

        TERMINAL.fetch(code) do
          raise ArgumentError, "unknown error code #{code.inspect}"
        end
      end

      def known?(code)
        code.to_s == KILLED || TERMINAL.key?(code.to_s)
      end
    end
  end
end
