# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/image"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class Image
          # What an application lists in `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Image::Vips, ... ]
          #
          # The library itself is in the cell, so what this names is which operation to ask.
          class Vips < Image
            self.client = Operations::Analyzers::Image::Vips
          end
        end
      end
    end
  end
end
