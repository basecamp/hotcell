# Passing Rails' own Tempfiles straight through. They are read-write, and the protocol requires a read-only
# input and a write-only output — an access mode is fixed at open, so a cell handed the wrong one can only
# decline the request.
require "active_storage/hot_cell/client/transformer"
module ActiveStorage
  module HotCell
    module Client
      class Transformer
        private def convert(file, output, payload)
          Clients::TransformImage.perform_in_hotcell [ file ], [ output ], payload
        end
      end
    end
  end
end
