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
#
# The OpenMP variables come from the cell's environment rather than being named here: the number belongs
# to the image, which is configured to match the container's CPU quota. Without them the restriction would
# hand `magick` the pool the image's bound was meant to take away. `run_tool` carries the same pair.
MiniMagick.restricted_env = true
MiniMagick.cli_env = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
                       "OMP_NUM_THREADS" => ENV["OMP_NUM_THREADS"],
                       "OMP_THREAD_LIMIT" => ENV["OMP_THREAD_LIMIT"] }.compact

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
        # input it cannot decode. MiniMagick::Invalid is an input `identify` rejects outright.
        # ImageProcessing::Error is the pipeline's own verdict on the input against the requested
        # transform — a multi-layer source into a single-layer destination, for example. All three are
        # the input's fault rather than the operation's; unclassified, each was a transient `failed`
        # that never marked the blob, so the same file spent a full conversion on every request.
        unreadable MiniMagick::Error, MiniMagick::Invalid, ImageProcessing::Error

        # **Accepted risk.** A tool's output is not bounded on this path. `Operation#run_tool` caps what it
        # reads at 64KB and drops the rest as it arrives, because an input that makes a tool print gigabytes
        # of diagnostics costs this worker gigabytes of address space, takes RLIMIT_DATA with it, and arrives
        # as a `memory` verdict — which is permanent, for a document whose only crime was being noisy.
        # mini_magick reads both streams to EOF in a thread apiece and has no setting that bounds either;
        # `graphicsmagick`, `cli_prefix`, `cli_env`, `restricted_env`, `timeout`, `logger`, `tmpdir`,
        # `errors` and `warnings` are the whole list. The premise is that patching the library is worse than
        # carrying this, and that the operations move off it: driving `magick` directly through `run_tool`
        # bounds the output, returns the environment to us, and sheds the input staging, which is
        # basecamp/hotcell#7.
      end
    end
  end
end
