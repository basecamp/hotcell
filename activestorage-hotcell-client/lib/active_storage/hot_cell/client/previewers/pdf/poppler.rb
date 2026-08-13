# frozen_string_literal: true

require "active_storage/previewer/poppler_pdf_previewer"

require "active_storage/hot_cell/client/previewers/previewing"
require "active_storage/hot_cell/client/previewers/pdf"

module ActiveStorage
  module HotCell
    module Client
      module Previewers
        module Pdf
          # The Poppler sibling of Mutool, for an application whose image carries pdftoppm rather than
          # mutool — the previewer Rails' default chain reaches first.
          class Poppler < ActiveStorage::Previewer::PopplerPDFPreviewer
            include Previewing

            self.client = Operations::Previewers::Pdf::Poppler

            def self.accept?(blob)
              pdf? blob.content_type
            end
          end
        end
      end
    end
  end
end
