# frozen_string_literal: true

require "hot_cell/test_cell"

# The shipped double plus the protocol-level helpers this suite needs. A consumer would use the real client
# instead of these; the server's own suite has no client to use, which is deliberate — nothing here should
# depend on hotcell-client being correct.
class TestCell < HotCell::TestCell
  # Inputs and outputs are paths here, and this opens them with the access modes the protocol requires.
  def call(op, inputs: [], outputs: [], payload: {}, **options)
    opened = inputs.map { |path| File.open(path, "rb") } + outputs.map { |path| File.open(path, "wb") }

    dispatch op, descriptors: wrap(opened, inputs.size), inputs: inputs.size, outputs: outputs.size,
                 payload: payload, **options
  ensure
    opened&.each(&:close)
  end

  # For the cases that have to be wrong on purpose: a mismatched count, or a descriptor whose access mode the
  # cell must refuse.
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

  private
    def wrap(opened, input_count)
      opened.each_with_index.map do |io, index|
        index < input_count ? HotCell::Input.new(io) : HotCell::Output.new(io)
      end
    end
end
