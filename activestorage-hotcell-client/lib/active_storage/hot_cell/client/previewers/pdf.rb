# frozen_string_literal: true

module ActiveStorage
  module HotCell
    module Client
      module Previewers
        # The two PDF previewers cannot share a base here: each subclasses the Rails previewer it replaces to
        # keep its content-type predicate, and those are different classes. The namespace is the shared home.
        module Pdf
        end

        PDF = Pdf
      end
    end
  end
end
