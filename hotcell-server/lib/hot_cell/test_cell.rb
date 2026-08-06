# frozen_string_literal: true

require "hot_cell/server"
require "fileutils"
require "tmpdir"

module HotCell
  # A real cell in a real process, for anybody's test suite.
  #
  # This ships here rather than being written again by each consumer, because every consumer otherwise
  # writes its own stub cell and they drift. It is not a stub: it forks, it passes descriptors, it applies
  # limits, and it reaps — none of which an in-process double would exercise, and all of which is where the
  # interesting failures are.
  #
  # The operations it carries are whatever the calling process has defined, because a worker inherits the
  # registry through the fork, exactly as a real cell does at boot.
  #
  #   HotCell::TestCell.boot(concurrency: 2) do |cell|
  #     HotCell.root = File.dirname(cell.directory)
  #     ...
  #   end
  class TestCell
    READY = "up"

    attr_reader :name, :directory, :workspace, :log_path

    def self.boot(**options)
      new(**options).start.tap do |cell|
        return cell unless block_given?

        begin
          yield cell
        ensure
          cell.stop
          cell.cleanup
        end
      end
    end

    # Anything in `supervisor:` goes to Supervisor.new; everything else is the cell's own limits.
    def initialize(name: "test", supervisor: {}, **options)
      @name = name
      @supervisor_options = supervisor
      @options = options
      @root = Dir.mktmpdir "hotcell-test"
      @directory = File.join(@root, name)
      @workspace = File.join(@root, "workspace")
      @log_path = File.join(@root, "cell.log")
    end

    # The parent of the cell's own directory, which is what a client registers as HotCell.root.
    def socket_root
      @root
    end

    # Writes a byte down a pipe once it is listening, so nothing here waits on a sleep.
    def start
      reader, writer = IO.pipe

      @pid = fork do
        reader.close
        HotCell.limits(**@options) unless @options.empty?

        supervisor = Supervisor.new(directory: directory, workspace: workspace,
                                    log: Log.new(File.open(log_path, "w")), **@supervisor_options)
        begin
          supervisor.boot
          writer.write READY
          writer.close
          supervisor.run
        rescue Exception => error # rubocop:disable Lint/RescueException
          File.write log_path, "#{error.class}: #{error.message}\n" \
                               "#{error.backtrace&.first(10)&.join("\n")}\n", mode: "a"
        ensure
          exit! 0
        end
      end

      writer.close
      ready = reader.read(READY.bytesize)
      reader.close
      raise "the cell did not boot: #{log}" unless ready == READY

      self
    end

    # Terminates the cell and leaves its files, so a test can read the log once everything that was going to
    # write to it has exited.
    def stop
      return if @pid.nil?

      begin
        Process.kill :TERM, @pid
        wait_for_exit
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      @pid = nil
    end

    def cleanup
      FileUtils.remove_entry @root if Dir.exist?(@root)
    end

    def log
      File.exist?(log_path) ? File.read(log_path) : ""
    end

    def log_events(event)
      log.lines.filter_map do |line|
        parsed = begin
          JSON.parse line, symbolize_names: true
        rescue JSON::ParserError
          nil
        end

        parsed if parsed.is_a?(Hash) && parsed[:event] == event
      end
    end

    private
      def wait_for_exit(within: 5)
        deadline = Clock.now + within

        loop do
          return if Process.wait(@pid, Process::WNOHANG)
          break if Clock.now > deadline

          sleep 0.01
        end

        Process.kill :KILL, @pid
        Process.wait @pid
      end
  end
end
