# frozen_string_literal: true

module HotCell
  # A cell is configured once, and everything about scheduling lives here rather than on an operation.
  #
  # These numbers are arithmetic against the container's own flags, not defaults to copy. Against a cell
  # given two CPUs, 2GB, and a 512MB tmpfs: concurrency 4 because the work is CPU-bound on two cores;
  # file_size 64MB because it bounds what one worker writes onto that tmpfs, and four of them share it;
  # and memory 1536MB because that is the measured working value for RLIMIT_DATA, which is per worker and
  # mostly reservation rather than resident bytes.
  #
  # What a worker writes is its outputs plus a copy of any input an operation asked for by path. An
  # operation that consumes the descriptor never pays for its input, which is what lets a small file_size
  # accept a large upload — but the kernel does not distinguish the two writes, so one number covers both.
  #
  # memory does not multiply by concurrency, and that is the easiest mistake to make here. It is an
  # address-space charge on one worker. The cgroup limit is what bounds real memory across the cell, and
  # it counts the tmpfs too, so size the two separately.
  class Configuration
    SCHEDULING = {
      concurrency:      4,   # workers running at once, and therefore the number of slots
      queue_size:       8,   # connections that may be accepted and waiting for one
      queue_wait:       10,  # seconds a queued connection may wait before it is answered `capacity`
      max_requests_per_worker:            1,   # requests a worker serves before it is discarded
      control_deadline: 5,   # seconds a control connection may take to send its request
    }.freeze

    LIMITS = {
      deadline:   60,
      memory:     1536 * 1024**2,
      file_size:  64 * 1024**2,
      open_files: 256,
    }.freeze

    UNLIMITED = :unlimited

    # Noticing an overdue worker, signalling it, reaping it, and writing the answer. Also the budget a
    # retired worker gets to exit before the supervisor kills its group — see Supervisor#enforce_retirements.
    KILL_GRACE = 1

    attr_reader(*SCHEDULING.keys)
    attr_reader :limits

    def initialize(**options)
      unknown = options.keys - SCHEDULING.keys - Limits::KEYS
      raise ConfigurationError, "unknown setting #{unknown.join(", ")}" if unknown.any?

      SCHEDULING.each { |key, default| instance_variable_set :"@#{key}", options.fetch(key, default) }

      # The two second-valued settings, coerced for the same reason Limits coerces deadline: they appear
      # in describe's JSON, and they may arrive as Active Support durations.
      @queue_wait = @queue_wait.to_f
      @control_deadline = @control_deadline.to_f

      # A nil is not "use the default" here, it is a missing number. A cell whose deadline is nil accepts
      # every request and then dies on the first arithmetic the supervisor does with it, so an explicit nil
      # has to be refused where it is written rather than where it is used.
      declared = options.slice(*Limits::KEYS)
      if (empty = declared.select { |_, value| value.nil? }.keys).any?
        raise ConfigurationError, "#{empty.join(", ")} cannot be nil; leave it out to take the default"
      end

      @limits = Limits.new(**LIMITS.merge(declared))

      verify!
    end

    def unlimited_requests?
      max_requests_per_worker == UNLIMITED
    end

    def retire?(served)
      !unlimited_requests? && served >= max_requests_per_worker
    end

    # What this cell expects to answer within, and deliberately not a bound it can keep: a worker in
    # uninterruptible sleep does not die when it is signalled, and the supervisor answers only after the
    # reap. Treat it as the threshold a client's timeout should clear, not as a guarantee to build a
    # correctness argument on.
    #
    # Derived here rather than reassembled in the client: a client adding up `queue_wait + deadline` plus its
    # own guess at the kill-to-answer step cannot follow a change to any of them, and the error points the
    # unsafe way — the client believes its timeout is generous and takes a transport failure instead of the
    # cell's verdict. A stage added later that costs a caller time belongs in this sum.
    def answer_within
      queue_wait + limits.deadline + KILL_GRACE
    end

    # Goes on the wire as the answer to hotcell.describe, so every value has to be JSON-native.
    # `max_requests_per_worker` is the one that is not: :unlimited is a Symbol, and a cell configured with it could
    # not describe itself at all.
    def to_h
      SCHEDULING.keys.to_h { |key| [ key, public_send(key) ] }
        .merge(limits.to_h)
        .merge(answer_within: answer_within,
               max_requests_per_worker: unlimited_requests? ? UNLIMITED.to_s : max_requests_per_worker)
    end

    private
      # `integer:` is a real distinction rather than an oversight, so it is written as one: a count of workers
      # or of queue places has to be whole, where a number of seconds does not.
      def verify!
        positive! :concurrency, integer: true
        positive! :queue_wait
        positive! :control_deadline

        unless queue_size.is_a?(Integer) && !queue_size.negative?
          raise ConfigurationError, "queue_size: #{queue_size} must not be negative"
        end

        unless unlimited_requests? || (max_requests_per_worker.is_a?(Integer) && max_requests_per_worker.positive?)
          raise ConfigurationError, "max_requests_per_worker: #{max_requests_per_worker.inspect} must be " \
                                    "a positive Integer or :unlimited"
        end
      end

      def positive!(key, integer: false)
        value = public_send(key)
        return if value.positive? && (!integer || value.is_a?(Integer))

        raise ConfigurationError, "#{key}: #{value} must be positive"
      end
  end
end
