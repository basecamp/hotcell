require "hot_cell/server"
module HotCell; class Supervisor
  private def drain_signals
    bytes = @signals.read_nonblock(256, exception: false)
    @stopping = true if bytes.is_a?(String) && bytes.include?("S")
  end
end; end
