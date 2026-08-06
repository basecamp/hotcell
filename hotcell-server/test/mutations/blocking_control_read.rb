# Reading a control request to completion, which parks the loop on a half-sent line.
require "hot_cell/server"
module HotCell
  class Supervisor
    private def read_control(socket)
      pending = pending_control(socket)
      @control_pending.delete pending
      line, = pending.connection.receive_message
      line.nil? ? pending.connection.close : answer_control(pending.connection, line)
    end
  end
end
