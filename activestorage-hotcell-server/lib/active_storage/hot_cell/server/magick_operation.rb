# frozen_string_literal: true

require "active_storage/hot_cell/server/operation"

# Loaded here rather than lazily in a worker, so mini_magick resolves the ImageMagick binary once at boot
# rather than shelling out to find it on the first request under a tight limit. mini_magick shells out for
# every operation, so unlike libvips there is no thread pool that fork would break — but keeping the two
# toolchains' loads in the same place is what makes a single cell carrying both legible.
require "image_processing/mini_magick"

# Invariant 9: a tool sees only the environment its operation wrote for it. `Operation#run_tool` holds it
# with `unsetenv_others: true`, and these operations do not use it — mini_magick spawns `magick` itself.
# `MiniMagick.restricted_env` is `false` by default, and with it false mini_magick calls
# `Open3.popen3({}, *command, unsetenv_others: false)`, so `magick` inherited this worker's whole
# environment. `bin/conformance` did not catch it, because its environment check drives an operation that
# goes through `run_tool`.
#
# `cli_env` names the locale for the reason `tool_environment` does: a tool's output must not shift under
# it. mini_magick passes `HOME`, `PATH` and `LANG` and does not pass `LC_ALL`, so both go here.
#
# Set at require time rather than in `before_worker_boot`, so that the binary lookup this require performs
# is covered too. Note what this is: mini_magick filters the environment it was given, where `run_tool`
# writes a fresh one. Driving `magick` directly would make it ours, and that is the separate enhancement
# this class already names.
MiniMagick.restricted_env = true
MiniMagick.cli_env = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }

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
