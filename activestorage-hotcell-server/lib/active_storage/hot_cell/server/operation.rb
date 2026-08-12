# frozen_string_literal: true

require "hot_cell/server"

module ActiveStorage
  # Despite the namespace, nothing here loads Active Storage. The name says which consumer these operations
  # serve, not what they link against, and the gem stays small because a smaller graph is a smaller thing to
  # audit — not because a cell polices what runs inside it. It does not: the container is the control, and what
  # an operation chooses to require is its own business.
  module HotCell
    # Everything the cell side defines lives under this, and everything the application side defines lives under
    # ActiveStorage::HotCell::Client. Not a tidying convention: the two gems are never both loaded in production,
    # and a cell is forked from a process that may well have loaded the client — after which a shared name is a
    # superclass mismatch while the cell boots. Two namespaces make that impossible rather than avoided.
    module Server
      # What every operation in this gem shares, whichever toolchain performs it.
      class Operation < ::HotCell::Operation
        abstract_operation

        # A lookup, not a gate: which format a caller may ask for is decided by the toolchain's own build,
        # the way Rails decides it. This only names the content type in a result, and a format it has never
        # heard of gets none.
        CONTENT_TYPES = {
          "png"  => "image/png",
          "jpg"  => "image/jpeg",
          "jpeg" => "image/jpeg",
          "webp" => "image/webp",
          "gif"  => "image/gif",
          "avif" => "image/avif",
          "tiff" => "image/tiff",
        }.freeze

        private
          # A caller breaking the protocol is a caller bug, not a bad document. Raising MessageError is what
          # makes the cell answer `invalid`, which is permanent and which the client raises rather than
          # turning into a placeholder.
          def refuse!(message)
            raise ::HotCell::MessageError, message
          end
      end
    end
  end
end
