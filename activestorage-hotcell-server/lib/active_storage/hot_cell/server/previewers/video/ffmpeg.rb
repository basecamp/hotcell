# frozen_string_literal: true

require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      module Previewers
        module Video
          # What `ActiveStorage::Previewer::VideoPreviewer` does, moved out of the application.
          #
          # Rails runs `ffmpeg <input args> -i <file> <output args> -` and lets an application set both
          # argument lists as shell strings it splits with Shellwords. This honours the input half:
          # `video_preview_input_arguments` arrives split, and it goes before `-i` exactly as it does in
          # Rails, because that is where an input option has to be. The output half is fixed here — see
          # RELEVANT_FRAME — and the only other thing a caller says is how many seconds in to seek.
          class Ffmpeg < ToolOperation
            operation "active_storage.previewers.video.ffmpeg"

            # Video is the reason a cell exists as a separate accessory. A preview measured in minutes and a
            # thumbnail measured in milliseconds must not share a concurrency limit, so this is sized to be
            # given a cell of its own rather than dropped in beside the image operations.
            limits deadline: 120, memory: 1536 * 1024**2, file_size: 128 * 1024**2, open_files: 128

            MAX_SEEK = 86_400

            # Rails' own frame selection, verbatim from the 7.0 defaults: frame 0, keyframes, and scene changes
            # over 0.015 are selected, and the loop/trim pair yields the second of those with the first as the
            # fallback — so a video that opens on black previews as its first scene rather than as the black.
            # This is the output half of `video_preview_arguments`, and it stays fixed: the input half is
            # what an application needs to shape, and that travels separately as `input_arguments`.
            RELEVANT_FRAME = 'select=eq(n\,0)+eq(key\,1)+gt(scene\,0.015),loop=loop=-1:size=2,trim=start_frame=1'

            def perform(inputs, outputs, seek: 0, input_arguments: [])
              source, = inputs
              destination, = outputs

              seek = seek!(seek)
              input_arguments = arguments!(:input_arguments, input_arguments)

              # JPEG rather than PNG, because Rails' own video previewer yields image/jpeg and this is meant to
              # drop into its place. A preview that changed the attached blob's content type would not be a
              # replacement.
              #
              # -ss before -i seeks by keyframe, which is orders of magnitude cheaper on a long file than
              # decoding up to the point. -nostdin because ffmpeg reads the terminal otherwise, and a worker has
              # no terminal. The application's input arguments go directly before -i, so they cannot drift
              # past it as the fixed flags around them change.
              #
              # Both descriptors go to ffmpeg: it reads /dev/fd for the source and writes /dev/fd for the frame,
              # so neither the input nor the output touches scratch on Linux. On darwin the source is staged
              # first, so a video larger than this operation's file_size is refused there rather than previewed. Writing the descriptor directly leaves
              # partial bytes in the caller's file on a mid-write failure where a staged output would have left
              # it empty — harmless here, because run! turns a non-zero exit into a refusal and the previewer
              # discards its output on any failure, but it is a real property of the direct write.
              run! "ffmpeg", "-nostdin", "-loglevel", "error", "-ss", seek.to_s,
                   *input_arguments, "-i", source.fd_path,
                   "-vf", RELEVANT_FRAME,
                   "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "-y", destination.fd_path,
                   pass: [ source.to_io, destination.to_io ]

              { format: "jpg", content_type: "image/jpeg", seek: seek,
                bytes: produced!(destination.to_io.stat.size, "ffmpeg") }
            end

            private
              def seek!(seek)
                return seek if seek.is_a?(Numeric) && !seek.negative? && seek <= MAX_SEEK

                refuse! "seek #{seek.inspect} must be a number of seconds between 0 and #{MAX_SEEK}"
              end
          end
        end
      end
    end
  end
end
