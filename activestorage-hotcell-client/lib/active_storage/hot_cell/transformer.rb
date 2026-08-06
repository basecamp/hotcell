# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_storage/transformers/transformer"

require "active_storage/hot_cell/clients"
require "active_storage/hot_cell/transformations"

module ActiveStorage
  module HotCell
    # What Rails configures as `config.active_storage.variant_processor`.
    #
    #   config.active_storage.variant_processor = ActiveStorage::HotCell::Transformer
    #
    # Note what adopting this does not achieve, because it is easy to assume otherwise: libvips is still loaded
    # into the application process, by `require "active_storage/engine"`, before any configuration is read. The
    # engine builds its default analyzers array by referencing ActiveStorage::Analyzer::ImageAnalyzer::Vips,
    # which requires ruby-vips, which dlopens the library. No `variant_processor` value changes that. Getting
    # the library out of the application means removing ruby-vips from the bundle, which then breaks that
    # default array — an application's call, and not one configuration alone can make.
    #
    # What this does achieve is that no untrusted byte is decoded there.
    class Transformer < ActiveStorage::Transformers::Transformer
      private
        # Returns an open, rewound Tempfile, which is the contract.
        def process(file, format:)
          output = Tempfile.new([ "hotcell", ".#{format}" ], binmode: true)

          begin
            convert file, output, Transformations.call(transformations, format: format)
            output.tap(&:rewind)
          rescue Exception # rubocop:disable Lint/RescueException
            output.close!
            raise
          end
        end

        # Both handles are reopened by path, narrowly, and that is the protocol rather than fussiness. Rails
        # hands out Tempfiles, which are read-write; an input descriptor must be read-only and an output
        # write-only. An access mode is fixed at open, so a cell handed the wrong one cannot narrow it — it can
        # only decline the request.
        def convert(file, output, payload)
          File.open(file.path, "rb") do |readable|
            File.open(output.path, "wb") do |writable|
              Clients::TransformImage.perform_in_hotcell [ readable ], [ writable ], payload
            end
          end
        end
    end
  end
end
