# frozen_string_literal: true

module HotCell
  # Unlinks what the supervisor renamed aside, in a process of its own.
  #
  # How long a recursive delete takes is chosen by the input that filled the tree, so it runs in neither
  # the supervisor, whose loop enforces every deadline, nor a worker's request. A worker sweeps its own
  # slot after it has answered, but a worker killed at its deadline never reaches that ensure — and a slot
  # whose every request is killed stacked one tree per kill until the scratch was full. This is the sweep
  # that needs no request to run: the supervisor forks it on a timer, holds it to a deadline, and never
  # runs two at once.
  class Sweeper
    def initialize(workspace:, configuration:, log:)
      @workspace = workspace
      @configuration = configuration
      @log = log
    end

    # exit! for the reason Worker#run does: nothing inherited from the supervisor may run its teardown here.
    #
    # The cell's limits go on first, as a worker's do. `FileUtils.remove_entry` lists a directory before it
    # unlinks anything in it, so a tree one directory wide enough allocates in proportion to its width — and
    # under RLIMIT_DATA that is this process's NoMemoryError and a `sweeper.crashed` line, where without it
    # the cgroup's OOM killer picks a process the cell needs.
    def run
      configuration.limits.apply
      started = Clock.now
      swept = slots.sum { |slot| sweep slot }

      log.write "scratch.swept", pid: Process.pid, swept: swept, duration_ms: Clock.ms_since(started)
      exit! 0
    rescue Exception => error
      log.write "sweeper.crashed", pid: Process.pid, error: error.class.name, message: Failure.sanitize(error.message)
      exit! 1
    end

    private
      attr_reader :workspace, :configuration, :log

      def slots
        (0...configuration.concurrency).map { |number| Slot.build(workspace, number) }
      end

      # A tree that would not go is the worker's `slot.unswept`, from this pid: the same fact, whoever
      # noticed it. The glob can raise — the slot directory is a name a tool can replace — and that too is
      # a slot left unswept rather than the end of the sweep.
      def sweep(slot)
        trees = slot.discarded
        removed = trees.count { |path| Filesystem.remove_tree(path) }
        report_unswept slot if removed < trees.size
        removed
      rescue SystemCallError
        report_unswept slot
        0
      end

      def report_unswept(slot)
        log.write "slot.unswept", pid: Process.pid, slot: slot.number, home: slot.directory
      end
  end
end
