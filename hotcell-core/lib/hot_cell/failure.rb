# frozen_string_literal: true

module HotCell
  # A cell's verdict on a request that did not succeed.
  #
  # The message is untrusted and it outlives the request. It comes out of a worker that has just parsed
  # a hostile file, and Vips::Error#message routinely contains the input filename. Applications store
  # these as durable blob metadata so they can re-decide later against a newer library, which means an
  # unscrubbed byte sequence becomes a permanently poisoned row, and an invalid UTF-8 sequence makes a
  # downstream regex raise ArgumentError instead of answering false.
  #
  # So the message is capped and scrubbed here, and that is not only hygiene: a cell that could not
  # serialize its own error could not answer at all. The client scrubs again on receipt, because
  # JSON.parse is not a filter — a \uD800 escape parses into an invalid UTF-8 String without complaint.
  class Failure
    MAX_MESSAGE_BYTES = 512

    attr_reader :code, :message, :error_class, :cause, :signal

    # Every field is sanitized, not only the message. All five arrive from the wire on the client side, so
    # all five carry whatever the peer put there — and they travel further than the message does, into
    # `to_s`, into the `perform.hot_cell` event, and into whatever a subscriber writes down. `code` in
    # particular is the field applications store. Scrubbing one and not the other four left the same
    # poisoned row the scrub exists to prevent, reachable through a different key.
    def initialize(code:, permanent: nil, message: nil, error_class: nil, cause: nil, signal: nil)
      @code = self.class.sanitize(code).to_s
      @cause = self.class.sanitize(cause)
      @signal = self.class.sanitize(signal)
      @error_class = self.class.sanitize(error_class)
      @message = self.class.sanitize(message)
      @permanent = permanent.nil? ? Codes.permanent?(@code, cause: @cause) : permanent
    end

    def permanent?
      @permanent
    end

    # compact rather than four guards: the constructor puts every one of these through `&.to_s` or
    # `sanitize`, so each is a String or nil and there is no falsey-but-meaningful value to protect.
    # `permanent` is the exception and survives, because compact drops only nil.
    def to_h
      { code: code, permanent: permanent? }
        .merge(cause: cause, signal: signal, class: error_class, message: message).compact
    end

    def to_s
      [ code, cause, error_class, message ].compact.join(": ")
    end

    class << self
      # Builds from either a message String or an Exception. An Exception has to become two wire fields, and
      # that rule was written out at three call sites across two gems — the worker, the supervisor's control
      # answer, and the client's transport.
      def for(code, detail, cause: nil)
        if detail.is_a?(Exception)
          new code: code, cause: cause, error_class: detail.class.name, message: detail.message
        else
          new code: code, cause: cause, message: detail
        end
      end

      # A code this client has never heard of is not permanent. An old client will meet a code added
      # later, and the harm of the two mistakes is not symmetrical: retrying something permanent costs
      # some work, while writing down a verdict that was temporary is irreversible.
      # A `permanent` that is present but not a boolean is derived rather than believed. Truthiness would make
      # any non-nil value permanent, and permanent is the answer that cannot be taken back — so a garbled
      # field must not be able to say it.
      def from_wire(wire)
        permanent = if [ true, false ].include?(wire[:permanent])
          wire[:permanent]
        else
          Codes.known?(wire[:code]) && Codes.permanent?(wire[:code], cause: wire[:cause])
        end

        new code: wire[:code], permanent: permanent, cause: wire[:cause], signal: wire[:signal],
            error_class: wire[:class], message: wire[:message]
      end

      # For a message that is about to be written as one line of a log. `sanitize` leaves CR and LF alone,
      # which is right for a message an application stores or re-raises, but a peer that puts a newline in
      # one writes a second log line of its own — formatted and indented like the real ones. Escape them,
      # and the rest of the control characters with them.
      def one_line(text)
        sanitize(text)&.gsub(/[[:cntrl:]]/) { |character| character.dump[1..-2] }
      end

      def sanitize(message)
        return nil if message.nil?

        String(message).dup.force_encoding(Encoding::UTF_8)
          .scrub("").byteslice(0, MAX_MESSAGE_BYTES).scrub("")
      end
    end
  end
end
