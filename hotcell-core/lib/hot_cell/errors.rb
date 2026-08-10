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

  # Either side configured wrongly. Raised at boot rather than at the first request, because a cell that
  # cannot hold its limits and a client that cannot classify a failure are both worse discovered in traffic.
  class ConfigurationError < Error; end

  # A peer that stopped mid-message. Distinct from a cell answering `timeout`, which is a verdict: this is
  # the caller's own deadline passing with the response incomplete.
  class ReadTimeout < Error; end

  # A client naming a cell nobody registered.
  class UnregisteredCell < Error; end

  # A client calling a cell whose socket directory is unset, which means the deployment has not turned this
  # path on. The caller is the one that knows what to do instead, so this is loud rather than silent.
  class CellNotConfigured < Error; end
end
