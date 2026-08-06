# frozen_string_literal: true

module HotCell
  # What an operation raises to choose its own verdict. An operation may also declare the library
  # exceptions that mean the same thing, with `unreadable Vips::Error`.
  class OperationError < StandardError; end

  # The input could not be decoded. Terminal: the same bytes fail the same way on an idle cell. Common
  # rather than exceptional — it covers truncated uploads, formats the build was not compiled with, and
  # formats deliberately refused.
  class UnreadableInput < OperationError; end

  # Reported as `killed` with `limit: memory` rather than as an ordinary failure, because it is the
  # decompression-bomb case and a caller must be able to act on it without parsing a message.
  class MemoryExhausted < OperationError; end
end
