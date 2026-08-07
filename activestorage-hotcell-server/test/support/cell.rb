# frozen_string_literal: true

require "hot_cell/test_cell"

# A real cell carrying the real operations, talking over a real socket, with real libvips inside it.
#
# The operations load in the cell's own process rather than in this one, and that is the whole reason this class
# exists. libvips' thread pool does not survive a fork: requiring it here would make every worker the cell forks
# block forever. So the suite speaks the protocol with hotcell-core, which loads no image library at all.
class Cell < HotCell::TestCell
  LOAD_OPERATIONS = -> { require "active_storage/hot_cell/server" }

  def self.boot(**options, &block)
    refuse_to_fork_a_poisoned_process
    super(operations: LOAD_OPERATIONS, **options, &block)
  end

  # A test that so much as names one of the operation classes drags libvips into this process, and from then on
  # every worker any cell forks blocks forever in futex_do_wait. The symptom is the whole suite hanging until its
  # timeouts fire, with nothing to say why. This turns that into one sentence.
  def self.refuse_to_fork_a_poisoned_process
    return unless defined?(::Vips)

    raise "libvips is loaded in the test process, so every worker this cell forks would deadlock. Something " \
          "required it — naming an operation class here is enough. Operations load inside the cell, in " \
          "Cell::LOAD_OPERATIONS."
  end

  def call(op, inputs: [], outputs: [], payload: {}, timeout: 30)
    opened = inputs.map { |path| File.open(path, "rb") } + outputs.map { |path| File.open(path, "wb") }
    descriptors = opened.each_with_index.map do |io, index|
      index < inputs.size ? HotCell::Input.new(io) : HotCell::Output.new(io)
    end

    request = HotCell::Request.new(op: op, inputs: inputs.size, outputs: outputs.size, payload: payload)

    connect do |connection|
      connection.send_message request.to_line, descriptors: descriptors
      answer connection, timeout
    end
  ensure
    opened&.each(&:close)
  end

  def connect(socket_name = "work.sock")
    socket = UNIXSocket.new File.join(directory, socket_name)
    connection = HotCell::Connection.new(socket)

    begin
      yield connection
    ensure
      connection.close
    end
  end

  def answer(connection, timeout = 30)
    raise "the cell did not answer within #{timeout}s. Log:\n#{log}" unless connection.socket.wait_readable(timeout)

    line = connection.read_line
    line && HotCell::Response.parse(line)
  end
end
