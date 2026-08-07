# frozen_string_literal: true

require "hot_cell/server"

# Loaded here, in the supervisor, rather than lazily in a worker.
#
# Two reasons, and the second is the one that bites. It forces libvips' loader plugins to be dlopened now: left
# to load lazily in a worker, they load *after* that worker's limits are on, and a tight memory limit makes
# dlopen fail with only a VIPS-WARNING — after which the process runs on with HEIC and AVIF quietly missing. A
# resource-limit breach becomes `unreadable` for an entire format family, which is the worst confusion this
# error taxonomy can produce.
#
# It is also what makes `unreadable Vips::Error` below expressible at all.
require "image_processing/vips"

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
      # Everything that parses an image with libvips, which happens in the worker's own address space.
      class VipsOperation < ::HotCell::Operation
        abstract

        # libvips parses here, in this process, so `reuse` is a security setting for these operations and not
        # only a performance one.
        untrusted_input :in_process

        # Vips::Error is how libvips reports a file it cannot decode, which is common rather than exceptional: it
        # covers truncated uploads, formats this build was not compiled with, and formats deliberately refused by
        # block_untrusted. All of those are the input's fault and none is the operation's.
        unreadable Vips::Error

        # Requires and configures. It must never evaluate an image, and the reason is mechanical: libvips starts
        # its thread pool on the first evaluation, that pool does not survive fork, and the child then waits on a
        # pool with no threads.
        #
        # Measured on this design's own machine, with libvips 8.18: after the require and the block below, the
        # process has three threads and every forked child converts. One `Vips::Image.black(1,1).avg` takes it to
        # five, and from then on every forked child blocks forever in futex_do_wait. Not the first child — every
        # child. The suite holds this.
        before_fork do
          unless Vips.respond_to?(:block_untrusted)
            raise ::HotCell::ConfigurationError,
                  "libvips' unfuzzed operations are not safe on untrusted content and this build cannot disable " \
                  "them. That needs libvips 8.13 or later and ruby-vips 2.2.1 or later."
          end
        end

        # There is no `Vips.block_untrusted true` here, and that is a decision rather than an omission.
        #
        # The gemspec pins image_processing to 2.0 or later, which blocks libvips' unfuzzed loaders as it loads.
        # It skips that call when `VIPS_BLOCK_UNTRUSTED` is in the environment, and measuring rather than reading
        # is what settled this: libvips honours that variable itself, so the loaders are blocked with the variable
        # unset, set, or set to the empty string. A call here would be a fourth road to a place already reached
        # three ways.
        #
        # What none of them covers is somebody calling `Vips.block_untrusted false` afterwards — and a call at
        # worker boot would not cover it either, since an operation could do it inside `perform`.
        # blocked_loaders_test.rb holds the property, which is the thing worth holding.
        #
        # The operation cache is set to nothing on purpose. Above `reuse: 1` it would span requests inside one
        # worker, which is a place one request's image data can sit while the next one runs.
        before_worker_boot do
          Vips.concurrency_set Integer(ENV.fetch("VIPS_CONCURRENCY", "2"))
          Vips.cache_set_max 0
          Vips.cache_set_max_mem 0
        end

        # What a caller may ask to be given back. Not a general format list: every entry here is a saver this cell
        # is willing to run.
        FORMATS = {
          "png"  => "image/png",
          "jpg"  => "image/jpeg",
          "jpeg" => "image/jpeg",
          "webp" => "image/webp",
          "gif"  => "image/gif",
          "avif" => "image/avif",
          "tiff" => "image/tiff",
        }.freeze

        private
          # A caller asking for something outside the allowlist is a caller bug, not a bad document. Raising
          # MessageError is what makes the cell answer `invalid`, which is terminal and which the client raises
          # rather than turning into a placeholder.
          def refuse!(message)
            raise ::HotCell::MessageError, message
          end

          def format!(payload)
            format = payload[:format].to_s.downcase
            refuse! "format #{payload[:format].inspect} is not one of #{FORMATS.keys.join(", ")}" unless FORMATS.key?(format)

            format
          end

          # EXIF says the pixels are stored rotated, so the dimensions a caller cares about are swapped. Rails'
          # own analyzer does the same thing for the same orientations.
          SWAPPED_ORIENTATIONS = (5..8)

          def dimensions_of(image)
            if SWAPPED_ORIENTATIONS.cover?(orientation_of(image))
              { width: image.height, height: image.width }
            else
              { width: image.width, height: image.height }
            end
          end

          def orientation_of(image)
            image.get("exif-ifd0-Orientation").to_i
          rescue ::Vips::Error
            0
          end

          # The only number that says whether a cell's `memory` limit is sized right: RSS understates the charge
          # and VmSize overstates it by more than twice.
          def vips_highwater
            ::Vips.tracked_mem_highwater
          end
      end
    end
  end
end
