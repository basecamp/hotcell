# One retry on failure, which doubles a cell's load at the moment it is least able to take it.
require "hot_cell/client"
module HotCell
  module Transport
    class Socket
      alias_method :call_once, :call
      def call(cell, line, descriptors, **options)
        response = call_once(cell, line, descriptors, **options)
        response.ok? ? response : call_once(cell, line, descriptors, **options)
      end
    end
  end
end
