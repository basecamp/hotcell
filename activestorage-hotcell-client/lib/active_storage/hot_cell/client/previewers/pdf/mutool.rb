# frozen_string_literal: true

require "active_storage/previewer/mupdf_previewer"

require "active_storage/hot_cell/client/previewers/previewing"
require "active_storage/hot_cell/client/previewers/pdf"

module ActiveStorage
  module HotCell
    module Client
      module Previewers
        module Pdf
          # What Rails configures in `config.active_storage.previewers`, replacing MuPDFPreviewer.
          class Mutool < ActiveStorage::Previewer::MuPDFPreviewer
            include Previewing

            self.client = Operations::Previewers::Pdf::Mutool

            # Delegates to the superclass's content-type predicate rather than restating the list, so the
            # accepted set cannot drift away from the one Rails ships.
            def self.accept?(blob)
              pdf? blob.content_type
            end
          end
        end
      end
    end
  end
end
