# frozen_string_literal: true

module HotCell
  # The gem cannot pick an application's exception classes, because two applications already do
  # irreconcilable things with the same one. HEY puts ActiveStorage::PreviewError in an
  # UNPROCESSABLE_ERRORS list and writes metadata["unprocessable"] = true, which no code path anywhere in
  # that application ever un-writes. BC4 never marks at representation time and splits on the cache header
  # instead, serving a file-icon placeholder with a hundred-year expiry for a permanent failure and
  # no-store for anything else.
  #
  # So a gem that raised PreviewError for a capacity refusal would, on HEY, permanently destroy the
  # thumbnail of every blob viewed during a cell restart, with no recovery short of a hand-written backfill.
  # `permanent` on the wire says which class to raise; injection is what stops the gem from guessing.
  #
  # These two are the fallback for a registration that injected neither. They are deliberately classes no
  # application already rescues, so an unclassified failure surfaces as a loud 500 rather than as a silent
  # permanent mark. Loud is the right way round.
  class PermanentFailure < StandardError; end

  # Must not descend from PermanentFailure, and that is not a stylistic point: the inheritance graph is the
  # classification, so a later tidying pass that gives both a common ancestor silently turns every retryable
  # failure into a permanent one.
  class TransientFailure < StandardError; end
end
