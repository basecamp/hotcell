# frozen_string_literal: true

require "active_storage"
require "active_storage/transformers/transformer"

require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/transformers/transforming"

module ActiveStorage
  module HotCell
    module Client
      module Transformers
        # What Rails configures as `config.active_storage.variant_processor`.
        #
        #   config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Vips
        #
        # Named for its toolchain the way ActiveStorage::Transformers::Vips is, because an ImageMagick sibling is
        # a planned addition rather than a hypothetical one.
        #
        # Note what adopting this does not achieve, because it is easy to assume otherwise: libvips is still loaded
        # into the application process, by `require "active_storage/engine"`, before any configuration is read. The
        # engine builds its default analyzers array by referencing ActiveStorage::Analyzer::ImageAnalyzer::Vips,
        # which requires ruby-vips, which dlopens the library. No `variant_processor` value changes that. Getting
        # the library out of the application means removing ruby-vips from the bundle, which then breaks that
        # default array — an application's call, and not one configuration alone can make.
        #
        # What this does achieve is that no untrusted byte is decoded there.
        class Vips < ActiveStorage::Transformers::Transformer
          include Transforming

          self.client = TransformImage
        end
      end
    end
  end
end
