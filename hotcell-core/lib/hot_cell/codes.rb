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
      "unsupported" => true,   # unknown operation name
      "protocol"    => false,  # version mismatch, which heals when the accessory reboots
      "capacity"    => false,  # the queue is full
      "unavailable" => false,  # no connection, or a connection closed with no response
      "timeout"     => false,  # the client's own deadline fired
    }.freeze

    # `killed` splits on what the worker hit, because a caller cannot otherwise tell a decompression
    # bomb from a slow afternoon. Size and memory are properties of the input, so the same bytes will
    # do it again on an idle cell. A deadline is as much a property of the load, and treating it as
    # terminal means a busy hour permanently condemns whatever was uploaded during it.
    TERMINAL_BY_LIMIT = {
      "fsize"    => true,
      "memory"   => true,
      "deadline" => false,
      "signal"   => true,
    }.freeze

    KILLED = "killed"

    class << self
      def terminal?(code, limit: nil)
        code = code.to_s
        return TERMINAL_BY_LIMIT.fetch(limit.to_s, true) if code == KILLED

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
