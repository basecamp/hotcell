# frozen_string_literal: true

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/analyzers/image"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        class Image
          # What an application on ImageMagick lists in `config.active_storage.analyzers`.
          #
          #   config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Image::Magick, ... ]
          #
          # It shares the base's width-and-height slice and its permanent-versus-transient split, differing
          # only in the client it reaches.
          class Magick < Image
            self.client = Operations::Analyzers::Image::Magick
          end
        end
      end
    end
  end
end
