# frozen_string_literal: true

# This file and every test run on Ruby 1.9.3, so they keep to what it has.
require "minitest/autorun"
require "socket"
require "tempfile"
require "tmpdir"

require "hot_cell/client/legacy"

# Ruby 1.9.3 to 2.1 bundle a minitest older than 5, which has no Minitest::Test.
LegacyTestCase = defined?(Minitest::Test) ? Minitest::Test : MiniTest::Unit::TestCase

class LegacyTest < LegacyTestCase
  private
    def client(options = {})
      HotCell::Client::Legacy.new(ENV.fetch("HOTCELL_WORK_SOCKET"), options)
    end

    def with_files(contents)
      source = Tempfile.new("source")
      destination = Tempfile.new("destination")
      source.write contents
      source.flush

      yield source.path, destination.path
    ensure
      source.close!
      destination.close!
    end

    def elapsed
      started = Time.now
      yield
      Time.now - started
    end

    # A peer that accepts one connection, reads the request, and does whatever `answer` does with the
    # connection, standing in for a cell that misbehaves in a way a real one cannot be made to. The connection
    # stays open until the test ends unless `answer` closes it.
    def with_peer(answer)
      Dir.mktmpdir do |directory|
        path = File.join(directory, "work.sock")
        server = UNIXServer.new(path)
        peer = Thread.new do
          connection = server.accept
          connection.gets
          answer.call connection
          sleep
        end

        begin
          yield HotCell::Client::Legacy.new(path, timeout: 0.5)
        ensure
          peer.kill
          server.close
        end
      end
    end
end
