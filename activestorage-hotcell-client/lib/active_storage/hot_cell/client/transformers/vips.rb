# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_storage/transformers/transformer"

require "active_storage/hot_cell/client/operations"

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
          private
            # Returns an open, rewound Tempfile, which is the contract.
            #
            # The transformations travel to the cell almost as they arrived. Rails hands this a symbol-keyed hash
            # with :format already removed — Variation deep-symbolizes on the way in and builds the transformer
            # with `transformations.except(:format)` — so the keys need nothing, and deciding which keys are
            # allowed belongs to the operation rather than to this side of the socket. Values are another matter:
            # Variation symbolizes only keys, so `crop: :attention` reaches here as the application wrote it, and
            # stock Rails-on-vips accepts it. A Symbol value cannot ride JSON, which is this gem's transport
            # detail rather than the application's problem — so Symbol values go over as the Strings vips would
            # have been handed anyway.
            def process(file, format:)
              output = Tempfile.new([ "hotcell", ".#{format}" ], binmode: true)

              begin
                convert file, output, format: format.to_s, operations: stringified(transformations)
                output.tap(&:rewind)
              rescue StandardError
                output.close!
                raise
              end
            end

            # Both handles are reopened by path, narrowly, and that is the protocol rather than fussiness. Rails
            # hands out Tempfiles, which are read-write; an input descriptor must be read-only and an output
            # write-only. An access mode is fixed at open, so a cell handed the wrong one cannot narrow it — it can
            # only decline the request.
            def convert(file, output, **payload)
              File.open(file.path, "rb") do |readable|
                File.open(output.path, "wb") do |writable|
                  TransformImage.perform_in_hotcell [ readable ], [ writable ], payload
                end
              end
            end

            # Only Symbol values, and only to String. Anything else unserializable is refused by the payload
            # check as ever, because for everything but a Symbol there is no value Rails would have accepted
            # in its place.
            def stringified(value)
              case value
              when Symbol then value.to_s
              when Hash   then value.transform_values { |nested| stringified(nested) }
              when Array  then value.map { |nested| stringified(nested) }
              else value
              end
            end
        end
      end
    end
  end
end
