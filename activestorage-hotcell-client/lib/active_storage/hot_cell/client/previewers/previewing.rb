# frozen_string_literal: true

require "tempfile"
require "active_storage"
require "active_support/core_ext/class/attribute"

require "active_storage/hot_cell/client/operations"

module ActiveStorage
  module HotCell
    module Client
      module Previewers
        # The preview flow every previewer here shares. A previewer names the client that renders for it and
        # differs in nothing else.
        #
        # **`accept?` must not probe for a binary, and that is the reason these previewers exist as much as the
        # sandboxing is.** `MuPDFPreviewer.accept?` calls `mutool_exists?` and `VideoPreviewer.accept?` calls
        # `ffmpeg_exists?`, both shelling out with `system` from inside a web request. The moment those binaries
        # leave the application image — which is the point of moving the work into a cell — both answer false,
        # `previewable?` goes false with them, and previews stop existing. No exception, no alert, nothing in a
        # log.
        #
        # The sequencing matters as much as the override: these ship and are verified *before* the binary leaves
        # the application image, because the window between those two events fails silently.
        module Previewing
          def self.included(previewer)
            previewer.class_attribute :client, instance_accessor: false
          end

          def preview(**options)
            download_blob_to_tempfile do |input|
              render_through(input) do |attachable|
                yield(**attachable, **options)
              end
            end
          end

          private
            # The filename extension and content type come from the cell's own result rather than being
            # restated here, so the operation is the one source of truth for what it produced. The scratch
            # tempfile's name never reaches Rails — only the yielded filename does.
            def render_through(input)
              Tempfile.create("hotcell-preview", binmode: true) do |output|
                result = File.open(input.path, "rb") do |readable|
                  File.open(output.path, "wb") do |writable|
                    self.class.client.perform_in_hotcell [ readable ], [ writable ]
                  end
                end

                File.open(output.path, "rb") do |io|
                  yield io: io, filename: "#{blob.filename.base}.#{result[:format]}",
                        content_type: result[:content_type]
                end
              end
            end
        end
      end
    end
  end
end
