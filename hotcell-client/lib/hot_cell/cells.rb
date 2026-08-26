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
    attr_reader :group

    # Takes the String an environment variable holds, so the initializer is one assignment with no
    # coercion. `to_i` would read garbage as gid 0 — root's group — so a value that is not a number
    # raises instead.
    def group=(value)
      @group = value.nil? ? nil : Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigurationError, "HotCell.group is #{value.inspect} and must be a numeric gid"
    end

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

    # Call once at boot, after registering. Warns and carries on; see Cell#describe.
    def describe_cells
      warn_about_group
      cells.each_value.to_h { |cell| [ cell.name, cell.describe ] }
    end

    # A group this process does not hold cannot be given to a file, so without this the first conversion
    # fails as EPERM from the client's own chown — after the deployment is live and carrying traffic. The
    # check is local and needs no cell, so it reports a missing `group-add` even when every cell is down.
    def warn_about_group
      return if group.nil? || group == Process.gid || group == Process.egid
      return if Process.groups.include?(group)

      logger.warn "hotcell: HotCell.group is #{group} and this process is in #{Process.groups.sort.inspect}, " \
                  "so it cannot put a descriptor in that group and every conversion will fail with EPERM. " \
                  "Add the group to this container (Kamal: `group-add` under the role's `options:`), or " \
                  "unset HotCell.group where both sides run as one user."
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
