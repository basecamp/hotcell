# One keyword whose removal changes nothing observable in normal operation, and leaks the worker's whole
# environment into every converter.
require "hot_cell/server"
module HotCell
  class Operation
    def convert(*command, env: {}, capture: 64 * 1024)
      require "open3"
      out, err, status = Open3.capture3(converter_environment(env), *command)
      Converted.new status, out.byteslice(0, capture), err.byteslice(0, capture)
    end
  end
end
