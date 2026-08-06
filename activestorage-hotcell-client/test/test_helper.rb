# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "logger"
require "tempfile"
require "tmpdir"
require "socket"
require "fileutils"

require "active_storage/hot_cell/client"

# The cell side, so these tests run the real thing end to end: a Rails transformer, over a Unix socket, into a
# forked worker that actually runs libvips.
require "hot_cell/test_cell"

require_relative "support/cell"
require_relative "support/blob"

class ActiveStorageHotCellClientTest < Minitest::Test
  # Stand-ins for an application's own classes, which the gem must never name for itself.
  class Unprocessable < StandardError; end
  class TemporarilyUnavailable < StandardError; end

  FIXTURES = File.expand_path("../../activestorage-hotcell-server/test/fixtures", __dir__)

  def setup
    HotCell.reset_registrations!
    HotCell.logger = Logger.new(File::NULL)

    # Rails sets this from the engine, which is not booted here. The analyzer writes to it when it decides a blob
    # is permanently unanalyzable.
    ActiveStorage.logger ||= Logger.new(File::NULL)
  end

  def teardown
    HotCell.reset_registrations!
    HotCell.logger = nil
  end

  private
    def fixture(name)
      File.join FIXTURES, name
    end

    # Boots a real cell carrying the real operations, and registers it the way an application's initializer does.
    def with_cell(name: ActiveStorage::HotCell::Client::CELL, register: {}, **options)
      Cell.boot(name: name, **options) do |cell|
        HotCell.root = cell.socket_root
        HotCell.register name, permanent: Unprocessable, transient: TemporarilyUnavailable, **register

        yield cell
      end
    end

    # For the cases about classification, where booting a cell to produce one verdict would be theatre.
    def with_canned_response(response, register: {})
      HotCell.root = "/nowhere"
      HotCell.register ActiveStorage::HotCell::Client::CELL, permanent: Unprocessable,
                       transient: TemporarilyUnavailable, transport: CannedTransport.new(response), **register
    end

    def failed(code, limit: nil, message: "no")
      HotCell::Response.failed HotCell::Failure.new(code: code, limit: limit, message: message),
                               timing: { perform_ms: 1 }
    end

    # Both built-in previewers memoize the answer to "is the binary there", so setting that memo says the binary
    # is gone without stubbing anything and without shelling out. It is also the state an application is in the
    # moment it removes mutool and ffmpeg from its image, which is the whole scenario.
    #
    # Every class in the chain, because the memo is a class-level instance variable and those are not inherited:
    # setting it on the superclass alone leaves a subclass to re-probe, find the binary installed on this
    # machine, and answer true for the wrong reason.
    def with_binary_missing(previewers, memo)
      was = previewers.to_h { |previewer| [ previewer, previewer.instance_variable_get(memo) ] }
      previewers.each { |previewer| previewer.instance_variable_set memo, false }
      yield
    ensure
      was.each { |previewer, value| previewer.instance_variable_set memo, value }
    end

    def identify(path)
      lines = `magick identify -format '%w %h %m\n' #{path.shellescape} 2>/dev/null`.lines
      skip "ImageMagick is not installed" if lines.empty?

      width, height, format = lines.first.split
      { width: Integer(width), height: Integer(height), format: format, frames: lines.size }
    end

    class CannedTransport
      def initialize(response)
        @response = response
      end

      def call(_cell, _line, _descriptors, socket: nil, timeout: nil)
        @response
      end
    end
end

require "shellwords"
