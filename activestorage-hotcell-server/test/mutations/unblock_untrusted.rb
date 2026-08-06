# Turning the unfuzzed loaders back on, which is what an application initializer that calls
# Vips.block_untrusted(false) after boot would do.
require "active_storage/hot_cell/server/vips_operation"
module ActiveStorage
  module HotCell
    module Server
      class VipsOperation
        @before_worker_boot = [ lambda do
          Vips.block_untrusted false
          Vips.concurrency_set Integer(ENV.fetch("VIPS_CONCURRENCY", "2"))
        end ]
      end
    end
  end
end
