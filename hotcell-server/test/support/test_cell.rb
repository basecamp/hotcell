# frozen_string_literal: true

require "fileutils"

# Boots a real cell in a real process and talks to it over a real socket, because the parts worth testing
# here are the fork, the descriptor passing, the signals, and the reap — none of which an in-process double
# would exercise.
#
# The cell writes a byte down a pipe once it is listening, so nothing here waits on a sleep.
class TestCell
  READY = "up"

  attr_reader :directory, :workspace, :log_path

  def initialize(**options)
    @options = options
    @root = Dir.mktmpdir "hotcell-test"
    @directory = File.join(@root, "cell")
    @workspace = File.join(@root, "work")
    @log_path = File.join(@root, "cell.log")
  end

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

  def start
    reader, writer = IO.pipe

    @pid = fork do
      reader.close
      HotCell.limits(**@options) unless @options.empty?

      supervisor = HotCell::Supervisor.new(directory: directory, workspace: workspace,
                                           log: HotCell::Log.new(File.open(log_path, "w")))
      begin
        supervisor.boot
        writer.write READY
        writer.close
        supervisor.run
      rescue Exception => error # rubocop:disable Lint/RescueException
        File.write log_path, "#{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}\n", mode: "a"
      ensure
        exit! 0
      end
    end

    writer.close
    ready = reader.read(READY.bytesize)
    reader.close
    raise "the cell did not boot: #{File.read(log_path) if File.exist?(log_path)}" unless ready == READY

    self
  end

  # Terminates the cell and leaves its files behind, so a test can read the log once everything that was
  # going to write to it has exited.
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

  # Inputs and outputs are paths here, and this opens them with the access modes the protocol requires.
  def call(op, inputs: [], outputs: [], payload: {}, **options)
    opened = inputs.map { |path| File.open(path, "rb") } + outputs.map { |path| File.open(path, "wb") }

    dispatch op, descriptors: wrap(opened, inputs.size), inputs: inputs.size, outputs: outputs.size,
                 payload: payload, **options
  ensure
    opened&.each(&:close)
  end

  # For the cases that have to be wrong on purpose: a mismatched count, or a descriptor whose access mode
  # the cell must refuse.
  def dispatch(op, descriptors: [], inputs: 0, outputs: 0, payload: {},
               version: HotCell::PROTOCOL_VERSION, timeout: 10)
    request = HotCell::Request.new(op: op, inputs: inputs, outputs: outputs, payload: payload,
                                   version: version)
    send_line request.to_line, descriptors: descriptors, timeout: timeout
  end

  def send_line(line, descriptors: [], timeout: 10)
    connect do |connection|
      connection.send_message line, descriptors: descriptors
      answer connection, timeout
    end
  end

  # Reaches the side-band channel, whose whole value is answering when the work socket cannot.
  def control(op, timeout: 10)
    connect("control.sock") do |connection|
      connection.send_message HotCell::Request.new(op: op).to_line
      answer connection, timeout
    end
  end

  # Opens a connection and hands it back without reading, so a test can hold several at once.
  def connect(socket_name = "work.sock")
    socket = UNIXSocket.new File.join(directory, socket_name)
    connection = HotCell::Connection.new(socket)
    return connection unless block_given?

    begin
      yield connection
    ensure
      connection.close
    end
  end

  def answer(connection, timeout = 10)
    unless connection.socket.wait_readable(timeout)
      raise "the cell did not answer within #{timeout}s. Log:\n#{log}"
    end

    line = connection.read_line
    line && HotCell::Response.parse(line)
  end

  def log
    File.exist?(log_path) ? File.read(log_path) : ""
  end

  def log_events(event)
    log.lines.filter_map do |line|
      parsed = JSON.parse(line, symbolize_names: true) rescue nil
      parsed if parsed && parsed[:event] == event
    end
  end

  private
    def wrap(opened, input_count)
      opened.each_with_index.map do |io, index|
        index < input_count ? HotCell::Input.new(io) : HotCell::Output.new(io)
      end
    end

    def wait_for_exit(within: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within

      loop do
        return if Process.wait(@pid, Process::WNOHANG)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end

      Process.kill :KILL, @pid
      Process.wait @pid
    end
end
