# frozen_string_literal: true

module HotCell
  # A cell is configured once, and everything about scheduling lives here rather than on an operation.
  #
  # These numbers are arithmetic against the container's own flags, not defaults to copy. Against a cell
  # given two CPUs, 2GB, and a 512MB tmpfs: concurrency 4 because the work is CPU-bound on two cores;
  # file_size 48MB because four workers each holding an input and an output is 384MB of that tmpfs; and
  # memory 1536MB because that is the measured working value for RLIMIT_DATA, which is per worker and
  # mostly reservation rather than resident bytes.
  #
  # memory does not multiply by concurrency, and that is the easiest mistake to make here. It is an
  # address-space charge on one worker. The cgroup limit is what bounds real memory across the cell, and
  # it counts the tmpfs too, so size the two separately.
  class Configuration
    SCHEDULING = {
      concurrency:      4,   # workers running at once, and therefore the number of slots
      queue_factor:     2,   # accepted-but-not-running connections, as a multiple of concurrency
      queue_wait:       10,  # seconds a queued connection may wait before it is answered `capacity`
      reuse:            1,   # requests a worker serves before it is discarded
      control_deadline: 5,   # seconds a control connection may take to send its request
    }.freeze

    LIMITS = {
      deadline:   60,
      memory:     1536 * 1024**2,
      file_size:  64 * 1024**2,
      open_files: 256,
    }.freeze

    UNLIMITED = :unlimited

    attr_reader(*SCHEDULING.keys)
    attr_reader :limits

    def initialize(**options)
      unknown = options.keys - SCHEDULING.keys - Limits::KEYS
      raise ConfigurationError, "unknown setting #{unknown.join(", ")}" if unknown.any?

      SCHEDULING.each { |key, default| instance_variable_set :"@#{key}", options.fetch(key, default) }
      @limits = Limits.new(**LIMITS.merge(options.slice(*Limits::KEYS)))

      verify!
    end

    # Saturation shows up as latency before it shows up as failure. A cell that only ever refused would
    # go from healthy to erroring with nothing in between and nothing to alarm on.
    def queue_size
      concurrency * queue_factor
    end

    def unlimited_reuse?
      reuse == UNLIMITED
    end

    def retire?(served)
      !unlimited_reuse? && served >= reuse
    end

    # A worker serving several requests holds each of them in the same address space, so an input that
    # achieves code execution can read and tamper with every later request that worker handles, with no
    # race to win. That trade is often the right one, and it must not be made silently by somebody
    # adding an operation to an existing cell.
    def in_process_warning(operations)
      return nil if reuse == 1

      exposed = operations.select { |operation| operation.untrusted_input == :in_process }
      return nil if exposed.empty?

      "reuse: #{reuse} with #{exposed.map(&:operation_name).join(", ")} parsing untrusted input in " \
        "process. An input that compromises a worker reaches up to #{reuse == UNLIMITED ? "every" : reuse - 1} " \
        "later request on it."
    end

    def to_h
      SCHEDULING.keys.to_h { |key| [ key, public_send(key) ] }.merge(limits.to_h)
    end

    private
      def verify!
        raise ConfigurationError, "concurrency: #{concurrency} must be positive" unless concurrency.is_a?(Integer) && concurrency.positive?
        raise ConfigurationError, "queue_factor: #{queue_factor} must not be negative" unless queue_factor.is_a?(Integer) && !queue_factor.negative?
        raise ConfigurationError, "queue_wait: #{queue_wait} must be positive" unless queue_wait.positive?
        raise ConfigurationError, "control_deadline: #{control_deadline} must be positive" unless control_deadline.positive?

        unless unlimited_reuse? || (reuse.is_a?(Integer) && reuse.positive?)
          raise ConfigurationError, "reuse: #{reuse.inspect} must be a positive Integer or :unlimited"
        end
      end
  end
end
