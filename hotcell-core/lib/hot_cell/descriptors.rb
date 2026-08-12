# frozen_string_literal: true

require "fcntl"

module HotCell
  # A descriptor, not a path. The cold side opens the file and passes the open descriptor, so no path a
  # hot side chooses is ever opened by the cold side, and no path the cold side chose is ever visible
  # to a tool.
  #
  # These verify rather than merely tag, and both sides verify. An access mode is fixed at open and
  # cannot be narrowed afterward, so a cell handed a read-write descriptor as an input cannot correct
  # it — it can only decline the request.
  class Descriptor
    MODES = {
      Fcntl::O_RDONLY => "read-only",
      Fcntl::O_WRONLY => "write-only",
      Fcntl::O_RDWR   => "read-write",
    }.freeze

    attr_reader :io

    def initialize(io, scratch: nil)
      @io = io
      @scratch = scratch
      verify_regular_file!
      verify_access_mode!
      verify_position!
    end

    def to_io
      io
    end

    # The path that reads or writes this descriptor in place, without a copy onto scratch. `/dev/fd/N`
    # names the open file behind fd N: the worker itself may open it (libvips does), and a spawned tool
    # sees it too when the worker hands the fd across the exec at the same number — see Operation#run_tool.
    #
    # This is what keeps a multi-gigabyte input off a small tmpfs: the descriptor is the caller's own file,
    # readable at any size, where staging it would be a write and RLIMIT_FSIZE bounds writes. Reopening
    # `/dev/fd/N` gives a fresh file description at offset zero, so a read here does not disturb the
    # descriptor the supervisor still holds.
    def fd_path
      "/dev/fd/#{io.fileno}"
    end

    def close
      io.close unless io.closed?
    end

    # Whether this descriptor has been given a filename on the worker's own scratch.
    def staged?
      !@path.nil?
    end

    private
      # The worker hands each descriptor the scratch it may stage onto; the client hands over nothing,
      # because a filename is the worker's concern and no path the cold side names must ever matter.
      def scratch_path
        raise Error, "#{self.class.name} has no scratch, so a path is not a question for this side" if @scratch.nil?

        @scratch.call
      end

      def verify_access_mode!
        mode = io.fcntl(Fcntl::F_GETFL) & Fcntl::O_ACCMODE
        return if mode == self.class::ACCESS_MODE

        raise AccessModeError, "#{self.class.name} needs a #{MODES.fetch(self.class::ACCESS_MODE)} " \
                               "descriptor, and this one is #{MODES.fetch(mode, "mode #{mode}")}"
      end

      # O_APPEND is a caller bug of the same shape as handing over a read-write descriptor, and it fails as
      # quietly: every write lands at the end whatever the cell does, so a conversion is appended to
      # whatever the file already held and the caller reads its old bytes followed by new ones. Like the
      # access mode this is fixed at open, so the only thing a cell can do about it is decline.
      def verify_position!
        return unless (io.fcntl(Fcntl::F_GETFL) & Fcntl::O_APPEND).positive?

        raise AccessModeError, "#{self.class.name} was opened with O_APPEND, so a conversion would be " \
                               "appended to what the file already holds rather than becoming its contents"
      end

      # A pipe as an output can deadlock a single streaming write against a cold side that is not
      # draining it, and a character device is nobody's conversion.
      def verify_regular_file!
        return if io.stat.file?

        raise AccessModeError, "#{self.class.name} needs a regular file, and this one is a #{io.stat.ftype}"
      end
  end

  class Input < Descriptor
    ACCESS_MODE = Fcntl::O_RDONLY

    # Copies the bytes onto the worker's own scratch on the first call and returns the filename. This is the
    # fallback, for an operation that genuinely needs a real file. Prefer `fd_path`, which reads the
    # descriptor in place: staging is a write, so RLIMIT_FSIZE bounds it, and an input larger than the
    # operation's file_size dies here as a permanent `fsize` verdict — a ceiling Rails does not have. The
    # Active Storage operations all read `fd_path` for exactly that reason; nothing should reach for `path`
    # without a specific need for a distinct on-disk copy.
    #
    # On call rather than up front, so an operation that never asks for a staged path never pays for the copy.
    def path
      @path ||= copied_to(scratch_path)
    end

    private
      def copied_to(path)
        File.open(path, "wb") { |file| IO.copy_stream(io, file) }
        path
      end
  end

  class Output < Descriptor
    ACCESS_MODE = Fcntl::O_WRONLY

    # Names the file the operation is to write, on the first call. Nothing is copied yet: post sends
    # the file back out through the descriptor, and an operation that writes the descriptor directly
    # never names one at all.
    def path
      @path ||= scratch_path
    end

    # Sends whatever the operation produced back out through the descriptor, and returns the byte count
    # the cold side can now read. Outputs are posted and flushed before success is reported, so a
    # caller may read as soon as it sees `ok`.
    #
    # A staged file that does not exist means the operation returned without writing anything. That
    # reports zero rather than raising, because zero bytes is a verdict the client already has to
    # handle: a full tmpfs arrives the same way.
    def post
      if staged?
        return 0 unless File.exist?(path)

        File.open(path, "rb") { |file| IO.copy_stream(file, io) }.tap { io.flush }
      else
        io.flush
        io.stat.size
      end
    end
  end
end
