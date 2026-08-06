# frozen_string_literal: true

require "hot_cell/test_cell"

# A real cell in a genuinely separate process, started the way a container starts one.
#
# The shipped `HotCell::TestCell` forks, which is right for a suite whose process holds nothing. This one spawns
# `exe/hotcell` with nothing but the three gems on its load path, which is what production does — so it is the
# more faithful harness, and it exercises the executable as well.
#
# It is also the only way to see what a cell's heap really looks like. These tests load Active Storage, which
# loads Active Record; a forked cell would inherit all of it and warn about the copy-on-write cost, and a
# consumer reading this file should see the shape they actually deploy rather than an artefact of the harness.
class Cell
  REPO = File.expand_path("../../..", __dir__)
  EXE = File.join(REPO, "hotcell-server", "exe", "hotcell")
  LIBS = %w[ hotcell-core hotcell-server activestorage-hotcell-server ].map { |gem| File.join(REPO, gem, "lib") }

  BOOT = <<~RUBY
    HotCell.limits concurrency: 2, deadline: 30, memory: 1200 * 1024**2, file_size: 32 * 1024 * 1024
    require "active_storage/hot_cell/server"
  RUBY

  attr_reader :name, :directory, :socket_root, :log_path

  def self.boot(name: "active_storage", **options)
    cell = new(name: name, **options).start
    return cell unless block_given?

    begin
      yield cell
    ensure
      cell.stop
      cell.cleanup
    end
  end

  def initialize(name: "active_storage", boot: BOOT)
    @name = name
    @boot = boot
    @root = Dir.mktmpdir "hotcell-client-test"
    @socket_root = @root
    @directory = File.join(@root, name)
    @operations = File.join(@root, "operations")
    @log_path = File.join(@root, "cell.log")
  end

  def start
    FileUtils.mkdir_p [ @directory, @operations ]
    File.write File.join(@operations, "00_boot.rb"), @boot

    @pid = Process.spawn(environment, RbConfig.ruby, *LIBS.flat_map { |lib| [ "-I", lib ] }, EXE,
                         out: @log_path, err: @log_path)
    wait_for_socket
    self
  end

  def stop
    return if @pid.nil?

    begin
      Process.kill :TERM, @pid
      Process.waitpid @pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    @pid = nil
  end

  def cleanup
    FileUtils.remove_entry @root if Dir.exist?(@root)
  end

  def log
    File.exist?(@log_path) ? File.read(@log_path) : ""
  end

  private
    def environment
      { "HOTCELL_DIR" => @directory, "HOTCELL_OPERATIONS" => @operations,
        "HOTCELL_WORKSPACE" => File.join(@root, "workspace") }
    end

    def wait_for_socket(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      socket = File.join(@directory, "work.sock")

      until File.socket?(socket)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline || !alive?
          raise "the cell never created its socket. Log:\n#{log}"
        end

        sleep 0.02
      end
    end

    def alive?
      Process.waitpid(@pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end
end
