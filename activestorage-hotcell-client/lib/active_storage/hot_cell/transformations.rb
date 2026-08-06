# frozen_string_literal: true

module ActiveStorage
  module HotCell
    # Turns a Rails transformations hash into the closed payload an operation understands.
    #
    # **This exists because a variant's address never expires.** A variant URL is a signed serialization of the
    # whole transformations hash, carried inside the URL rather than looked up server-side, so an email sent
    # three years ago carries `loader: { page: nil }, coalesce: true` and will still decode to that hash in five
    # more years — and the application hands it straight to the transformer.
    #
    # Three things follow, and the middle one is the whole reason this file exists rather than a migration.
    #
    # 1. Every historical shape has to keep working, permanently. Removing `loader` from what the client
    #    understands is what would break every image in every email ever sent.
    # 2. So the mapping happens here, at the boundary, rather than by asking callers to pass something else.
    # 3. Changing what new callers pass is not free either: it mints a new URL segment and a new
    #    variation_digest, orphaning every variant_records row for the old shape. So this maps, and leaves
    #    call sites alone.
    #
    # BC4's RewriteTransformations is the same fix one layer out.
    module Transformations
      # Library keywords a caller used to pass, and what each one actually meant.
      #
      # `loader` and `saver` are the operation's to choose — a cell exists so that a caller cannot hand a media
      # library its own options — so these are read for intent and then dropped. `coalesce` is ImageMagick's way
      # of saying the same thing `loader: { n: -1 }` says on vips.
      LIBRARY_KEYWORDS = [ :loader, :saver, :coalesce, :quality, :strip, :format ].freeze

      class << self
        def call(transformations, format:)
          rest = symbolize(transformations)
          intent = extract(rest)

          { format: format.to_s, operations: rest }.tap do |payload|
            payload[:animated] = true if intent[:animated]
            payload[:quality] = intent[:quality] if intent[:quality]
            payload[:strip] = true if intent[:strip]
          end
        end

        private
          def extract(rest)
            loader = symbolize(rest.delete(:loader) || {})
            saver = symbolize(rest.delete(:saver) || {})

            # Deleted rather than read: `default_to` merges format: into the hash before the URL key is signed,
            # so it arrives here as well as being passed separately. The argument is the one to trust.
            rest.delete :format

            # Every one of these is removed before any of them is combined. Deleting inside the `||` below would
            # short-circuit — when the loader has already said "animated", `rest.delete(:coalesce)` never runs,
            # and `coalesce` travels on to the cell as though it were a transformation.
            coalesce = rest.delete(:coalesce)
            quality = rest.delete(:quality)
            strip = rest.delete(:strip)

            { animated: every_frame?(loader) || truthy(coalesce),
              quality: saver[:quality] || saver[:Q] || quality,
              strip: truthy(saver[:strip]) || truthy(strip) }
          end

          # Two spellings of one request, from two libraries. `page: nil` is how HEY asks ImageMagick to keep
          # every frame of a GIF, and `n: -1` is how the same request is written for libvips.
          def every_frame?(loader)
            (loader.key?(:page) && loader[:page].nil?) || loader[:n].to_i.negative?
          end

          def symbolize(hash)
            return {} unless hash.respond_to?(:to_h)

            hash.to_h.each_with_object({}) { |(key, value), symbolized| symbolized[key.to_sym] = value }
          end

          def truthy(value)
            !!value && value != "false"
          end
      end
    end
  end
end
