# The caller's own bugs falling inside the transport rescue, where an application whose transient class
# descends from IOError would have them retried forever.
require "hot_cell/client"
module HotCell
  class Client
    alias_method :perform_without_swallowing, :perform_in_hotcell
    def perform_in_hotcell(inputs, outputs, payload = {})
      perform_without_swallowing inputs, outputs, payload
    rescue HotCell::Error => error
      raise self.class.cell.transient, error.message
    end
  end
end
