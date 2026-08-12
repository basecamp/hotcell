# frozen_string_literal: true

require "active_storage/hot_cell/server/operation"

# Loaded here rather than lazily in a worker, so mini_magick resolves the ImageMagick binary once at boot
# rather than shelling out to find it on the first request under a tight limit. mini_magick shells out for
# every operation, so unlike libvips there is no thread pool that fork would break — but keeping the two
# toolchains' loads in the same place is what makes a single cell carrying both legible.
require "image_processing/mini_magick"

module ActiveStorage
  module HotCell
    module Server
      # Everything that transforms or analyses an image with ImageMagick, through mini_magick.
      #
      # ImageMagick runs as an exec'd `magick` process that dies at the end of the call, so a decompression
      # bomb executes in a child rather than in this worker. What this does touch in-process is mini_magick's
      # own output — dimensions from `identify`, an exit status — which is a number and a string, not a
      # decoder. The distinction is the same one probe_media draws for ffprobe.
      #
      # Unlike the vips operations, the input is staged onto scratch: mini_magick spawns its own `magick` and
      # does not inherit this worker's descriptors, so an input cannot be handed to it as /dev/fd. That
      # returns the file_size ceiling to this path — an input larger than the operation's file_size dies
      # being staged — which the vips operations shed. Removing it means driving `magick` directly rather
      # than through mini_magick, and is a separate enhancement.
      class MagickOperation < Operation
        abstract_operation

        # MiniMagick::Error is how mini_magick reports a `magick` that exited non-zero — the common shape of an
        # input it cannot decode. MiniMagick::Invalid is an input `identify` rejects outright. Both are the
        # input's fault rather than the operation's.
        unreadable MiniMagick::Error, MiniMagick::Invalid
      end
    end
  end
end
