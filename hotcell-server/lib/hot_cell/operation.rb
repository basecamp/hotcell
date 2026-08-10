# frozen_string_literal: true

module HotCell
  # An operation declares only what is not an argument. Every operation on both sides takes the same
  # three: inputs, outputs, and a payload. There is no per-operation argument schema and no generated
  # code, and an operation that receives the wrong count fails inside perform and reports `failed`. The
  # blast radius of a miscounted argument is one worker with no network, and skipping the schema buys
  # back an entire declaration layer.
  #
  # This is the one place application code deliberately runs inside a cell. The invariant is not "no
  # application code": it is that the code running there has no credentials, no database, no network, and
  # no application configuration.
  class Operation
    READ_BYTES = 16 * 1024

    STAGING = [ :paths, :descriptors ].freeze
    UNTRUSTED_INPUT = [ :in_process, :subprocess ].freeze

    class << self
      include Declarations

      def inherited(subclass)
        super
        Registry.register subclass
      end

      # Declares a class that exists to be inherited from, not to be dispatched to.
      #
      # Every subclass registers, because that is what makes an operation reachable by writing it. An
      # intermediate that gathers shared setup registers too, and a cell then advertises it in `describe` and
      # accepts it on the wire — where it reaches a `perform` that raises NotImplementedError and answers
      # `failed`, as though the caller's document were the problem.
      #
      # Deliberately not inherited: a subclass of an abstract operation is concrete unless it says otherwise,
      # and a class-level instance variable is not visible to a subclass, so that falls out for free.
      def abstract_operation
        @abstract_operation = true
        Registry.reload!
      end

      def abstract_operation?
        @abstract_operation == true
      end

      # Writes the name the wire uses, defaulting to the underscored class name with namespaces as dots.
      def operation(name = nil)
        return operation_name if name.nil?

        @operation_name = name.to_s
        Registry.reload!
        @operation_name
      end

      def operation_name
        @operation_name || derived_operation_name
      end

      def limits(**values)
        return inherited_value(:@limits) || Limits.new if values.empty?

        @limits = Limits.new(**values)
      end

      # Where a malicious input gets to execute, which is what decides whether `reuse` is a security
      # setting for this operation or only a performance one.
      #
      # A subprocess converter parses in an exec'd child that dies at the end of the conversion, and the
      # worker only copies bytes, spawns, and reads an exit status — so recycling that worker buys
      # nothing. An in-process library parses in the worker's own address space, so recycling buys
      # isolation between requests. in_process is the default because it is the answer that makes `reuse`
      # mean something, and a wrong default should be the cautious one.
      #
      # This is a claim about the operation's own code and it is easy to break later. Reading the
      # converter's output with an in-process library to build `result`, or parsing its stderr, both turn
      # a nominally-subprocess operation into an in-process one. Test the claim rather than the comment.
      def untrusted_input(where = nil)
        return inherited_value(:@untrusted_input) || :in_process if where.nil?

        @untrusted_input = verify_one_of(where, UNTRUSTED_INPUT, "untrusted_input")
      end

      # Whether the worker copies the inputs onto its scratch and gives the operation filenames.
      #
      # Paths are the general model rather than a workaround: image_processing is filename-in and
      # filename-out, and mutool, ffmpeg, and ffprobe all take paths. Copying gives the tool a path the
      # cold side never named.
      #
      # Descriptors are for an operation that can consume one directly. ffprobe reads only a container
      # header, and making it copy a multi-gigabyte input onto a 512MB tmpfs first is not a corner case:
      # it is why thimble's video role abandoned descriptors for a shared volume, at roughly 300x I/O
      # amplification on its commonest call.
      def stage(mode = nil)
        return inherited_value(:@stage) || :paths if mode.nil?

        @stage = verify_one_of(mode, STAGING, "stage")
      end

      # Runs in the supervisor, once, at boot. It may require and it may configure, and it must never
      # evaluate an image.
      #
      # That rule is what the whole process model rests on, and breaking it is a silent hang rather than a
      # crash. Measured: a parent that has only required image_processing/vips and set concurrency has
      # three threads and forks children that work. One additional 1x1 evaluation takes it to five, and
      # from then on every forked worker blocks forever in futex_do_wait, because the GLib thread pool
      # does not survive fork and the child waits on a pool with no threads. Not the first worker — every
      # worker. A later change that pre-warms the pool to save the fork cost is exactly what this forbids.
      #
      # Note that a hotcell forks per request, continuously, so "before the fork" and "at boot" are not
      # the same moment the way they are in Puma. This runs once.
      def before_fork(&block)
        return collected(:@before_fork) if block.nil?

        (@before_fork ||= []) << block
      end

      # Runs in the worker after the fork and before it serves anything. This is where an operation sizes
      # its library, and the framework deliberately does not do it for anyone: Vips.concurrency_set 4 in a
      # cell given two CPUs running twenty workers is forty threads on two cores, and getting that right
      # is the operation author's problem against the cell's own numbers.
      #
      # Configuration belongs here rather than in before_fork because it is global and singular. Two
      # operations configuring the same library in the supervisor would silently disagree, with the last one
      # registered winning.
      #
      # A worker is not one operation, which is what makes this the right place rather than a safe one. Above
      # `reuse: 1` it can serve A, then B, then A, and these hooks re-run whenever the operation changes —
      # so what the library is set up for always matches what is about to run. Write them to be re-entrant:
      # they are setters against shared state, not one-time initialization.
      def before_worker_boot(&block)
        return collected(:@before_worker_boot) if block.nil?

        (@before_worker_boot ||= []) << block
      end

      # Library exceptions that mean the input could not be decoded, rather than that the operation broke.
      def unreadable(*classes)
        return collected(:@unreadable) + [ UnreadableInput ] if classes.empty?

        (@unreadable ||= []).concat classes
      end

      private
        def derived_operation_name
          Naming.default_operation_name self
        end

        def verify_one_of(value, allowed, setting)
          return value if allowed.include?(value)

          raise ConfigurationError, "#{setting}: #{value.inspect} must be one of #{allowed.inspect}"
        end

        # Superclass first, so a base class's hooks run before the ones that specialize it.
        def collected(variable)
          ancestors.grep(Class).reverse.flat_map { |ancestor| ancestor.instance_variable_get(variable) || [] }
        end
    end

    # A fresh instance per request, so that nothing an operation puts in an instance variable survives
    # into the next request a reused worker serves.
    def perform(inputs, outputs, payload)
      raise NotImplementedError, "#{self.class} must implement perform(inputs, outputs, payload)"
    end

    Converted = Struct.new(:status, :out, :err) do
      def ok?
        status.success?
      end
    end

    # Runs a converter with `unsetenv_others` and a fully written environment, never a filtered copy of this
    # worker's own. This is invariant 9, and it is the only point in the whole design where we control what a
    # converter's /proc/<pid>/environ shows.
    #
    # Filtering would not work. The worker is forked, so its own /proc/self/environ is the exec-time
    # environment of the process it was forked from, and ENV.delete changes nothing that a sibling worker can
    # read. An exec'd child is different: it gets a fresh environ, and this is where that gets written.
    #
    # Bounded output, because a converter's stdout is attacker-influenced. The environment is also why
    # parsing that output moves an operation from :subprocess to :in_process — see untrusted_input.
    # `capture` bounds what is kept AND what is read, which capture3 could not do. It accumulates both
    # streams in full and hands them over at exit, so slicing afterwards bounded the Strings this method
    # returns and nothing else: an input that makes a converter print gigabytes of diagnostics had already
    # cost gigabytes of this worker's address space, and took RLIMIT_DATA with it — arriving as a `memory`
    # verdict, which is terminal, for a document whose only crime was being noisy.
    def convert(*command, env: {}, capture: 64 * 1024)
      require "open3"

      Open3.popen3(converter_environment(env), *command, unsetenv_others: true) do |stdin, out, err, thread|
        stdin.close
        captured = drain(out, err, capture)

        Converted.new thread.value, captured[out], captured[err]
      end
    end

    private
      # Reads both streams until they close, keeping only the first `limit` bytes of each and discarding the
      # rest as it arrives. Both have to be read, not just the one being kept: a converter blocks writing to
      # a pipe nobody drains, and a converter blocked on stderr never exits, which turns a noisy document
      # into a deadline kill.
      def drain(*streams, limit)
        kept = streams.to_h { |stream| [ stream, +"".b ] }
        open = streams.dup

        until open.empty?
          readable, = IO.select(open)

          Array(readable).each do |stream|
            chunk = stream.read_nonblock(READ_BYTES, exception: false)
            next if chunk == :wait_readable

            if chunk.nil?
              open.delete stream
              next
            end

            room = limit - kept[stream].bytesize
            kept[stream] << chunk.byteslice(0, room) if room.positive?
          end
        end

        kept
      end

      def converter_environment(overrides)
        { "HOME" => ENV["HOME"], "PATH" => ENV["PATH"], "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }
          .merge(overrides.transform_keys(&:to_s))
          .compact
      end
  end
end
