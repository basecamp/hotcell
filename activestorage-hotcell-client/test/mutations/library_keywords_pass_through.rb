# Handing the whole transformations hash to the operation, library keywords and all. A cell exists so that a
# caller cannot choose a media library's own loader and saver options, and this puts that choice back.
require "active_storage/hot_cell/transformations"
module ActiveStorage
  module HotCell
    module Transformations
      def self.call(transformations, format:)
        { format: format.to_s, operations: transformations.to_h { |k, v| [ k.to_sym, v ] } }
      end
    end
  end
end
