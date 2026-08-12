# frozen_string_literal: true

module HotCell
  # What a worker may consume, and what a cell will let an operation ask for. `deadline` is seconds;
  # `memory` and `file_size` are bytes; `open_files` is a count. Active Support's helpers work —
  # `1280.megabytes` is a plain Integer already, and a `30.seconds` duration flattens to one on arrival.
  #
  # There is deliberately no RLIMIT_CPU. The deadline strictly covers it — anything that burns CPU also
  # burns wall clock, and the deadline additionally catches a worker blocked on a wedged subprocess,
  # which trips no CPU limit because a stuck worker consumes no CPU at all. The two numbers are related
  # by a factor nobody can predict, measuring 1.0x at libvips concurrency 1 and about 1.5x at 4, so a CPU
  # limit cannot be derived from a latency budget. And RLIMIT_CPU is cumulative over a process's life, so
  # it stops meaning "per request" the moment a worker serves a second one.
  #
  # What is given up is real: RLIMIT_CPU was kernel-enforced and would still fire if the supervisor's
  # timer logic were wrong. That is the reason to keep the supervisor's loop boring.
  class Limits
    # Below this a worker does not fail gracefully, it dies before it can answer, as SIGABRT or ENOMEM
    # during boot. Roughly 450MB of any RLIMIT_DATA is Ruby's own: since 3.3 the interpreter reserves a
    # single ~404MB writable anonymous region at boot that it never touches, and RLIMIT_DATA charges all
    # of it. So this is not "how much a bomb may consume" — subtract 450MB before reading it that way.
    MEMORY_FLOOR = 1024 * 1024**2

    # RLIMIT_DATA rather than RLIMIT_AS. RLIMIT_DATA charges private writable anonymous mappings and
    # ignores PROT_NONE reservations, read-only file mappings, and MAP_SHARED of any kind. Against a real
    # variant whose peak RSS is 45MB, RLIMIT_DATA works from 704MB where RLIMIT_AS needs 1536MB, and
    # RLIMIT_AS fails nondeterministically for a 400MB band below its floor. Do not add RLIMIT_AS as a
    # backstop: any value clearing that band already exceeds the container's own memory limit.
    RESOURCES = {
      memory:     Process::RLIMIT_DATA,
      file_size:  Process::RLIMIT_FSIZE,
      open_files: Process::RLIMIT_NOFILE,
    }.freeze

    KEYS = [ :deadline, *RESOURCES.keys ].freeze

    attr_reader(*KEYS)

    # to_f and to_i, because these travel as JSON and 30.seconds is an ActiveSupport::Duration until it
    # is asked to be a number.
    def initialize(deadline: nil, memory: nil, file_size: nil, open_files: nil)
      @deadline = deadline&.to_f
      @memory = memory&.to_i
      @file_size = file_size&.to_i
      @open_files = open_files&.to_i

      verify_positive!
      verify_memory_floor!
    end

    def [](key)
      public_send key
    end

    def to_h
      KEYS.to_h { |key| [ key, self[key] ] }
    end

    def declared
      to_h.compact
    end

    # An operation cannot exceed its cell's limits, whatever it declares. This is invariant 6, and a
    # clamp that silently stops clamping looks exactly like a clamp, which is why it is tested.
    def clamped_to(ceiling)
      self.class.new(**KEYS.to_h { |key| [ key, smaller(self[key], ceiling[key]) ] })
    end

    # The soft limit narrows to the operation and the hard limit stays at the cell's ceiling. An
    # unprivileged process can raise a soft limit up to its hard limit but can never raise a hard one, so
    # this is what lets a reused worker widen back for an operation with a different budget. Setting both
    # to the operation's value would make the first request the tightest the worker could ever be.
    def apply(ceiling: self)
      Process.setrlimit Process::RLIMIT_CORE, 0

      RESOURCES.each do |key, resource|
        soft = self[key]
        next if soft.nil?
        next if key == :memory && !self.class.memory_enforceable?

        begin
          Process.setrlimit resource, soft, ceiling[key] || soft
        rescue Errno::EINVAL
          raise unless key == :memory

          self.class.memory_unenforceable!
        end
      end
    end

    # macOS/XNU has no finite RLIMIT_DATA and returns EINVAL for any value, so the memory clamp cannot be set
    # there. Rather than crash every worker, warn once and run unclamped — the memory limit is a Linux property
    # and production is Linux. The suite skips the enforcement assertions off Linux.
    @memory_enforceable = true

    class << self
      def memory_enforceable?
        @memory_enforceable
      end

      def memory_unenforceable!
        return unless @memory_enforceable

        @memory_enforceable = false
        warn "hotcell: RLIMIT_DATA is not settable on #{RUBY_PLATFORM}; the cell's memory limit is not enforced"
      end
    end

    private
      def smaller(mine, theirs)
        return theirs if mine.nil?
        return mine if theirs.nil?

        [ mine, theirs ].min
      end

      def verify_positive!
        KEYS.each do |key|
          value = self[key]
          next if value.nil? || value.positive?

          raise ConfigurationError, "#{key}: #{value} must be positive"
        end
      end

      def verify_memory_floor!
        return if memory.nil? || memory >= MEMORY_FLOOR

        raise ConfigurationError,
              "memory: #{memory} is below the #{MEMORY_FLOOR} byte floor. About 450MB of RLIMIT_DATA is " \
              "Ruby's own untouched reservation, so a worker under the floor dies during boot rather " \
              "than failing gracefully."
      end
  end
end
