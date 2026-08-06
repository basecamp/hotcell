# What a cell with one socket would do: control shares the work queue, and goes quiet under load.
require "hot_cell/server"
module HotCell
  class Supervisor
    private def accept_control
      socket = @control.accept_nonblock(exception: false)
      return if socket == :wait_readable

      connection = Connection.new(socket)
      if running < configuration.concurrency || @queue.size < configuration.queue_size
        @queue << [ connection, Clock.now ]
      else
        refuse connection, "the queue is full"
      end
    end
  end
end
