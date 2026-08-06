# frozen_string_literal: true

module HotCell
  # The two things a cell answers that are not conversions, on control.sock rather than work.sock.
  #
  # Keeping control off the data path buys three things. It answers when the cell is saturated, where a
  # health check or a metrics scrape sharing the work queue would fail under load and report the same thing
  # as an outage. It gets its own allowance and its own much shorter deadline, which are not the same
  # numbers — a scrape is milliseconds and a conversion is seconds. And the socket a connection arrived on
  # is itself the discriminator, so routing costs nothing and cannot be confused by a payload.
  #
  # The supervisor answers these itself rather than forking a worker for them, which is a deliberate
  # departure from the original design. Forking would work — a child inherits the counters and could read
  # them without being told — but the whole value of this channel is being available when nothing else is,
  # and a channel that needs a fork to answer is a channel that goes quiet exactly when a fork is what is
  # failing. Neither operation takes a descriptor, touches a converter, or evaluates a byte of image data,
  # so none of the reasons the supervisor stays out of a conversion apply. Reading a bounded control line
  # from the trusted side starts no thread pool and cannot deadlock a later fork.
  class Control
    DESCRIBE = "hotcell.describe"
    METRICS = "hotcell.metrics"
    OPERATIONS = [ DESCRIBE, METRICS ].freeze

    def initialize(configuration:, counters:)
      @configuration = configuration
      @counters = counters
    end

    def answer(line, running:, queued:)
      request = Request.parse(line)

      unless request.current_version?
        return failed("protocol", "this cell speaks v#{PROTOCOL_VERSION} and the request is v#{request.version}")
      end

      case request.op
      when DESCRIBE then Response.ok(result: describe)
      when METRICS then Response.ok(result: @counters.to_h(running: running, queued: queued))
      else failed "unsupported", "control.sock answers #{OPERATIONS.join(" and ")}, not #{request.op.inspect}"
      end
    rescue MessageError => error
      failed "invalid", error.message
    end

    # Static, and called once per registered cell at app boot. It is the cheapest way to catch a client
    # pointed at a cell that does not carry the operation it wants, which is otherwise an `unsupported` on
    # the first real request, and to catch a client whose own timeout is below what this cell may take.
    def describe
      { v: PROTOCOL_VERSION, operations: Registry.names, **@configuration.to_h }
    end

    private
      def failed(code, message)
        Response.failed Failure.new(code: code, message: message)
      end
  end
end
