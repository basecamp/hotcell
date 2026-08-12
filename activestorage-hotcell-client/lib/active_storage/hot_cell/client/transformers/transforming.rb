# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/hash/deep_transform_values"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      module Transformers
        # The conversion both transformers share. A transformer names the client that carries its
        # transformations to the cell, and differs in nothing else.
        module Transforming
          def self.included(transformer)
            transformer.class_attribute :client, instance_accessor: false
          end

          private
            # Returns an open, rewound Tempfile, which is the contract.
            #
            # The transformations travel to the cell almost as they arrived. Rails hands this a symbol-keyed hash
            # with :format already removed — Variation deep-symbolizes on the way in and builds the transformer
            # with `transformations.except(:format)` — so the keys need nothing, and deciding which keys are
            # allowed belongs to the operation rather than to this side of the socket. Values are another matter:
            # Variation symbolizes only keys, so `crop: :attention` reaches here as the application wrote it, and
            # stock Rails accepts it. A Symbol value cannot ride JSON, which is this gem's transport detail
            # rather than the application's problem — so Symbol values go over as the Strings the toolchain
            # would have been handed anyway.
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
                  self.class.client.perform_in_hotcell [ readable ], [ writable ], payload
                end
              end
            end

            # Only Symbol values, and only to String. Anything else unserializable is refused by the payload
            # check as ever, because for everything but a Symbol there is no value Rails would have accepted
            # in its place.
            def stringified(transformations)
              transformations.deep_transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
            end
        end
      end
    end
  end
end
