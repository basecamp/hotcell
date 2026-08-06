# frozen_string_literal: true

module HotCell
  # What this gem raises when a call is wrong, as distinct from a cell's verdict on a conversion.
  #
  # These must be raised outside the client's transport rescue. An application injects its own
  # exception classes for a cell's verdicts, and if one of those descends from IOError then a bad call
  # swallowed by the transport rescue comes back as a socket failure and gets retried forever.
  class Error < StandardError; end

  # A payload or result value JSON cannot carry faithfully. Raised before anything is sent, because
  # to_json is not a check: it turns a Symbol into a String, a Time into a String, and an arbitrary
  # object into whatever its own to_json says, all silently and none of it reversible.
  class SerializationError < Error; end

  # A descriptor offered as an input that is not read-only, or as an output that is not write-only.
  # An access mode is fixed at open and cannot be narrowed afterward, so this can only be declined.
  class AccessModeError < Error; end

  # A message that is not what the protocol says it is: unparseable, too long, or missing a field.
  class MessageError < Error; end
end
