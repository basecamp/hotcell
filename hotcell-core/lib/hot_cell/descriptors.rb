# frozen_string_literal: true

require "fcntl"

module HotCell
  # A descriptor, not a path. The cold side opens the file and passes the open descriptor, so no path a
  # hot side chooses is ever opened by the cold side, and no path the cold side chose is ever visible
  # to a converter.
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

    attr_reader :io, :path

    def initialize(io)
      @io = io
      verify_regular_file!
      verify_access_mode!
    end

    def to_io
      io
    end

    def fileno
      io.fileno
    end

    def close
      io.close unless io.closed?
    end

    # Whether the worker has given this descriptor a filename on its own scratch.
    def staged?
      !path.nil?
    end

    private
      def verify_access_mode!
        mode = io.fcntl(Fcntl::F_GETFL) & Fcntl::O_ACCMODE
        return if mode == self.class::ACCESS_MODE

        raise AccessModeError, "#{self.class.name} needs a #{MODES.fetch(self.class::ACCESS_MODE)} " \
                               "descriptor, and this one is #{MODES.fetch(mode, "mode #{mode}")}"
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

    # Copies the bytes onto the worker's own scratch and returns the path. Every subprocess converter
    # wants a filename, and image_processing is filename-in and filename-out, so this is the general
    # model rather than a workaround. RLIMIT_FSIZE bounds this copy as well as the output, which is why
    # one number covers both.
    def stage(path)
      @path = path
      File.open(path, "wb") { |file| IO.copy_stream(io, file) }
      path
    end
  end

  class Output < Descriptor
    ACCESS_MODE = Fcntl::O_WRONLY

    # Names the file the operation is to write. Nothing is copied yet.
    def stage(path)
      @path = path
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
