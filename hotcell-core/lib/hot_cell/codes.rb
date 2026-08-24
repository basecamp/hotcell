# frozen_string_literal: true

module HotCell
  # Every failure carries a code and a `permanent` flag, and `permanent` is the only distinction that
  # changes what a caller must do.
  #
  # Terminal means the same request fails the same way until the input or the code changes — not until
  # the load or the deployment changes. A permanent failure may be recorded against a blob and served
  # from a cache. A non-permanent one must be retried and must never be written down.
  #
  # The flag travels on the wire, set by the side that knows, rather than being derived by each caller
  # from the code. That is what makes a code added later safe: an old client will not recognise it but
  # will still dispose of it correctly.
  module Codes
    PERMANENT = {
      "unreadable"  => true,   # the input could not be decoded — the operation said so explicitly
      "invalid"     => true,   # malformed request, or a descriptor that failed its access-mode check
      "failed"      => false,  # the operation raised something nobody classified — see below
      "unsupported" => false,  # this cell does not carry that operation — see below
      "protocol"    => false,  # version mismatch, which heals when the accessory reboots
      "capacity"    => false,  # the queue is full
      "unavailable" => false,  # no connection, or a connection closed with no response
      "timeout"     => false,  # the client's own deadline fired
    }.freeze

    # **`failed` is what an unclassified exception becomes, so it cannot be permanent.**
    #
    # A worker rescues StandardError around the whole request and calls it `failed`. Errno::ENOSPC is a
    # StandardError, and so are EMFILE, EIO, ENOENT and ENOMEM. A shared tmpfs filled by concurrent requests,
    # a full disk under the caller's own output, a descriptor table exhausted by load, a fork that cannot get
    # memory under host pressure, a tool missing during a broken deploy — every one of those raises inside
    # staging or writeback and arrives here. ENOMEM is the one that looks like the input's fault and is not:
    # the worker's own out-of-memory, where the input drove it past its limit, is a NoMemoryError, which the
    # worker classifies `killed`/`memory` instead.
    #
    # Terminal meant each of them was written down against a customer's file and served from a cache forever,
    # for a condition that would have succeeded on retry. Permanence has to be claimed, never inferred from
    # not knowing: an operation says `unreadable` for an input it could not decode, and the protocol says
    # `invalid` for a caller that broke its own contract. Everything else is this cell having a bad day.
    #
    # The cost of the other mistake is a genuinely broken operation being retried. That is bounded by the
    # job's attempts, it is visible in the `failed` rate, and it is recoverable.

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
    # permanent means a busy hour permanently condemns whatever was uploaded during it.
    # `crashed` is the cell's own fault rather than the input's — a worker that died without answering, which
    # a misconfigured cell does on every request. Recording that against a blob would condemn everything
    # uploaded during a broken deploy, so it is transient. An older client that has never heard of it still
    # disposes of it correctly, because `permanent` travels on the wire.
    #
    # **A limit this table has never heard of is not permanent, and that default is the point of the table.**
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
    CRASHED = "crashed"

    # `signal` is the unexplained death, and it is not permanent, because a signal says how a process died and
    # never why. The supervisor knows it sent SIGKILL for a deadline and says so. Every other signal arrived
    # from somewhere it cannot see: a cgroup OOM kill chosen on aggregate pressure across concurrent workers,
    # or one worker signalling another — they share a uid, and nothing stops that. Attributing either to the
    # input this worker happened to be holding condemns a file for something it did not do.
    #
    # So the two permanent causes are never inferred from a signal. They arrive only from the worker, over
    # the control socket only it holds: `memory` when it catches NoMemoryError itself, and `fsize` when a
    # write of its own returns EFBIG. See Worker#disarm_file_size_signal for why the file-size verdict has
    # to be earned that way rather than read off a wait status.
    PERMANENT_BY_CAUSE = {
      FSIZE    => true,
      MEMORY   => true,
      DEADLINE => false,
      CRASHED  => false,
    }.freeze

    KILLED = "killed"

    class << self
      def permanent?(code, cause: nil)
        code = code.to_s
        return PERMANENT_BY_CAUSE.fetch(cause.to_s, false) if code == KILLED

        PERMANENT.fetch(code) do
          raise ArgumentError, "unknown error code #{code.inspect}"
        end
      end

      def known?(code)
        code.to_s == KILLED || PERMANENT.key?(code.to_s)
      end
    end
  end
end
