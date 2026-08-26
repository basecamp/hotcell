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
  # failing. Neither operation takes a descriptor, touches a tool, or evaluates a byte of image data,
  # so none of the reasons the supervisor stays out of a conversion apply. Reading a bounded control line
  # from the trusted side starts no thread pool and cannot deadlock a later fork.
  class Control
    def initialize(configuration:, counters:)
      @configuration = configuration
      @counters = counters
    end

    def answer(line, running:, queued:)
      request = Request.parse(line)

      unless request.current_version?
        return failed("protocol", request.version_mismatch)
      end

      case request.op
      when DESCRIBE then Response.ok(result: describe)
      when METRICS then Response.ok(result: @counters.to_h(running: running, queued: queued))
      else failed "unsupported", "control.sock answers #{CONTROL_OPERATIONS.join(" and ")}, not #{request.op.inspect}"
      end
    rescue MessageError => error
      failed "invalid", error.message
    end

    # Static, and called once per registered cell at app boot. It is the cheapest way to catch a client
    # whose own timeout is below what this cell may take, and it is what `bin/hotcell describe` reads.
    def describe
      { v: PROTOCOL_VERSION, operations: Registry.names, groups: groups, **@configuration.to_h }
    end

    private
      # What a caller's files must carry for this cell to open one by name. The number in an application's
      # deploy file has to agree with the gid baked into this image, and nothing else compares them — so a
      # cell whose gid moved is a boot warning in the client rather than an EACCES on every conversion.
      #
      # The primary gid is added because getgroups is not required to report it.
      def groups
        (Process.groups + [ Process.gid ]).uniq.sort
      end

      def failed(code, message)
        Response.failed Failure.new(code: code, message: message)
      end
  end
end
