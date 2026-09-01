# frozen_string_literal: true

module HotCell
  # Every operation takes inputs, outputs, and the payload — and the payload arrives as keyword
  # arguments. There is no argument schema and no generated code, but an operation may declare the
  # specific keywords it wants (`format:, operations: {}`), and Ruby validates them on arrival; one that
  # wants the payload as a plain Hash declares `**payload` as its third argument, and one that takes no
  # options declares neither. A mismatched call raises inside perform and reports `failed`, and the
  # blast radius of that is one worker with no network.
  #
  # This is the one place application code deliberately runs inside a cell. The invariant is not "no
  # application code": it is that the code running there has no credentials, no database, no network, and
  # no application configuration.
  class Operation
    READ_BYTES = 16 * 1024

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

      # Writes the routing name, defaulting to the underscored class name with namespaces as dots.
      def operation(name = nil)
        return operation_name if name.nil?

        @operation_name = name.to_s
        Registry.reload!
        @operation_name
      end

      def operation_name
        @operation_name || derived_operation_name
      end

      # A class-level declaration that accumulates. Naming one limit changes one and keeps the rest — of this
      # class's own declaration, or of the nearest ancestor's when this class has none yet. That is what
      # lets a subclass narrow a single number, and what lets an operator give a shipped operation a
      # different budget from an operations file, after the operation loads, without editing the gem. The
      # cell's own limits still clamp whatever is declared. docs/DEPLOYMENT.md, "Changing a shipped
      # operation's limits".
      def limits(**values)
        return inherited_value(:@limits) || Limits.new if values.empty?

        @limits = limits.merge(**values)
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
      # `max_requests_per_worker: 1` it can serve A, then B, then A, and these hooks re-run whenever the operation
      # changes — so what the library is set up for always matches what is about to run. Write them to be
      # re-entrant: they are setters against shared state, not one-time initialization.
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

        # Superclass first, so a base class's hooks run before the ones that specialize it.
        def collected(variable)
          ancestors.grep(Class).reverse.flat_map { |ancestor| ancestor.instance_variable_get(variable) || [] }
        end
    end

    # A fresh instance per request, so that nothing an operation puts in an instance variable survives
    # into the next request a reused worker serves.
    def perform(inputs, outputs, **)
      raise NotImplementedError, "#{self.class} must implement perform(inputs, outputs, <keywords>)"
    end

    ToolResult = Struct.new(:status, :out, :err) do
      def ok?
        status.success?
      end
    end

    # Runs a tool with `unsetenv_others` and a fully written environment, never a filtered copy of this
    # worker's own. This is invariant 9, and it is the only point in the whole design where we control what a
    # tool's /proc/<pid>/environ shows.
    #
    # Filtering would not work. The worker is forked, so its own /proc/self/environ is the exec-time
    # environment of the process it was forked from, and ENV.delete changes nothing that a sibling worker can
    # read. An exec'd child is different: it gets a fresh environ, and this is where that gets written.
    #
    # Bounded output, because a tool's stdout is attacker-influenced — and worth remembering when an
    # operation parses it, because doing so brings the bytes a tool was isolating back into this worker.
    #
    # `capture` bounds what is kept AND what is read, which capture3 could not do. It accumulates both
    # streams in full and hands them over at exit, so slicing afterwards bounded the Strings this method
    # returns and nothing else: an input that makes a tool print gigabytes of diagnostics had already
    # cost gigabytes of this worker's address space, and took RLIMIT_DATA with it — arriving as a `memory`
    # verdict, which is permanent, for a document whose only crime was being noisy.
    # `pass` hands the tool a set of the worker's own descriptors — an input to read, an output to write —
    # at their existing fd numbers, so the tool reaches them at `Descriptor#fd_path` — `/dev/fd/N`, or the
    # file's own path on macOS, where opening `/dev/fd/N` would share the worker's offset — and no
    # byte is copied onto scratch to give it a filename. A fd handed to a child this way loses its
    # close-on-exec, which is exactly the inheritance wanted, and only for these; the worker's other
    # descriptors are untouched. Passing an fd at its own number cannot collide with the stdio pipes popen3
    # installs on 0, 1 and 2, because a received descriptor is never one of those.
    def run_tool(*command, env: {}, capture: 64 * 1024, pass: [])
      require "open3"

      inherit = pass.to_h { |io| [ io.fileno, io.fileno ] }

      Open3.popen3(tool_environment(env), *command, unsetenv_others: true, **inherit) do |stdin, out, err, thread|
        stdin.close
        captured = drain(out, err, capture)

        ToolResult.new thread.value, captured[out], captured[err]
      end
    end

    private
      # Reads both streams until they close, keeping only the first `limit` bytes of each and discarding the
      # rest as it arrives. Both have to be read, not just the one being kept: a tool blocks writing to
      # a pipe nobody drains, and a tool blocked on stderr never exits, which turns a noisy document
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

      # The OpenMP variables come from the cell's environment rather than being named here: the number
      # belongs to the image, which is configured to match the container's CPU quota. Without them
      # `unsetenv_others: true` would hand an exec'd tool the pool the image's bound was meant to take away.
      def tool_environment(overrides)
        { "HOME" => ENV["HOME"], "PATH" => ENV["PATH"], "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
          "OMP_NUM_THREADS" => ENV["OMP_NUM_THREADS"], "OMP_THREAD_LIMIT" => ENV["OMP_THREAD_LIMIT"] }
          .merge(overrides.transform_keys(&:to_s))
          .compact
      end
  end
end
