# frozen_string_literal: true

module HotCell
  # Checked, never negotiated. A cell answers `protocol` to anything else, which is transient rather
  # than a bug: during a rolling deploy the app moves before the accessory reboots, so every request
  # mismatches until it does.
  PROTOCOL_VERSION = 1

  # A request is a control message from the trusted side, and the worker parses it before it has
  # narrowed to the operation's limits. Capping it is what bounds that parse.
  MAX_REQUEST_BYTES = 8192

  # A response carries metadata rather than bytes, so this is generous rather than tight.
  MAX_RESPONSE_BYTES = 65_536

  # The kernel caps SCM_RIGHTS at 253 descriptors per message. Nothing here wants more than a handful.
  MAX_DESCRIPTORS = 16

  # Nesting depth of a whole message line. Deep symbolization walks the structure, so this is what
  # bounds the recursion.
  MAX_NESTING = 8
end
