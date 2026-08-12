# frozen_string_literal: true

require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      # What `ActiveStorage::Previewer::VideoPreviewer` does, moved out of the application.
      #
      # Rails runs `ffmpeg -i <file> -y -vframes 1 -f image2 -` and lets an application override those arguments
      # with a string it splits with Shellwords. This does not take arguments from anybody: the caller says how
      # many seconds in to seek and nothing else, because `video_preview_arguments` is a shell string and a cell
      # exists so that a caller cannot choose what a tool runs.
      class PreviewVideoOperation < ToolOperation
        operation "active_storage.preview_video"

        # Video is the reason a cell exists as a separate accessory. A preview measured in minutes and a thumbnail
        # measured in milliseconds must not share a concurrency limit, so this is sized to be given a cell of its
        # own rather than dropped in beside the image operations.
        limits deadline: 120, memory: 1536 * 1024**2, file_size: 128 * 1024**2, open_files: 128

        MAX_SEEK = 86_400

        # Rails' own frame selection, verbatim from the 7.0 defaults: frame 0, keyframes, and scene changes
        # over 0.015 are selected, and the loop/trim pair yields the second of those with the first as the
        # fallback — so a video that opens on black previews as its first scene rather than as the black.
        # Fixed here rather than taken from the caller, because `video_preview_arguments` is the shell string
        # this operation exists to not accept.
        RELEVANT_FRAME = 'select=eq(n\,0)+eq(key\,1)+gt(scene\,0.015),loop=loop=-1:size=2,trim=start_frame=1'

        def perform(inputs, outputs, seek: 0)
          source, = inputs
          destination, = outputs

          seek = seek!(seek)

          # JPEG rather than PNG, because Rails' own video previewer yields image/jpeg and this is meant to drop
          # into its place. A preview that changed the attached blob's content type would not be a replacement.
          #
          # -ss before -i seeks by keyframe, which is orders of magnitude cheaper on a long file than decoding up
          # to the point. -nostdin because ffmpeg reads the terminal otherwise, and a worker has no terminal.
          run! "ffmpeg", "-nostdin", "-loglevel", "error", "-ss", seek.to_s, "-i", source.fd_path,
               "-vf", RELEVANT_FRAME,
               "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "-y", destination.path,
               pass: [ source.to_io ]

          { format: "jpg", content_type: "image/jpeg", seek: seek,
            bytes: produced!(destination.path, "ffmpeg") }
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
