# frozen_string_literal: true

require "logger"

module HotCell
  class << self
    # The directory a cell's name resolves under, holding one subdirectory per cell. Unset means no cell is
    # reachable at all, which is the off position of the whole rollout.
    attr_accessor :root

    # The group both sides hold, so a cell can open a caller's file by name. An operation that hands a tool
    # a filename re-opens the descriptor as `/dev/fd/N`, and the kernel rechecks that open against the
    # cell's own credentials rather than the caller's — so a file only this application can read fails with
    # EACCES however the descriptor was passed. Set this to the cell's gid and put the application in that
    # group; the client then narrows each descriptor's mode on the way out. See Client#wrap.
    #
    # Leave it unset where both sides already run as one user, which is how development runs.
    attr_accessor :group

    attr_writer :logger

    def logger
      @logger ||= Logger.new($stderr)
    end

    # Cells are registered once.
    #
    #   HotCell.root = ENV.fetch("HOTCELL_ROOT", "/run/hotcell")
    #
    #   HotCell.register "active_storage",
    #     permanent: ActiveStorage::PreviewError,
    #     transient: MyApp::ConversionTemporarilyUnavailable
    #
    #   HotCell.register "archiver", dir: -> { ENV["HOTCELL_ARCHIVER_DIR"] }, timeout: 300
    def register(name, **options)
      Cell.new(name, **options).tap { |cell| cells[cell.name] = cell }
    end

    def cells
      @cells ||= {}
    end

    def cell(name)
      cells.fetch(name.to_s) do
        raise UnregisteredCell, "no cell named #{name.to_s.inspect} is registered (#{cells.keys.inspect})"
      end
    end

    # Whether a name is registered, for a caller with a fallback rather than a requirement.
    def cell?(name)
      cells.key?(name.to_s)
    end

    # Every HotCell::Client subclass, so a boot check can tell which cell is expected to carry what. This
    # records what the process has loaded rather than what it has configured, so resetting registrations
    # leaves it alone: the classes are still defined either way.
    def clients
      @clients ||= []
    end

    # Call once at boot, after registering. Warns and carries on; see Cell#describe.
    def describe_cells
      cells.each_value.to_h { |cell| [ cell.name, cell.describe ] }
    end

    # Test support. Named apart from the server gem's own reset, because both gems open this module and a
    # shared name would mean whichever loaded last silently won.
    def reset_registrations!
      @cells = nil
      @root = nil
      @group = nil
    end
  end
end
