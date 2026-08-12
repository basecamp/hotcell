# frozen_string_literal: true

require "json"
require "active_storage/hot_cell/server/tool_operation"

module ActiveStorage
  module HotCell
    module Server
      # What Rails' video and audio analyzers do, moved out of the application: ffprobe, and the numbers it
      # reports shaped exactly as `Analyzer::VideoAnalyzer` and `Analyzer::AudioAnalyzer` shape them.
      #
      # **This reads its tool's stdout, and that is a judgement, so here it is.**
      #
      # ffprobe parses the media in an exec'd child that dies at the end of the call. What comes back into this
      # worker is JSON on a bounded buffer, parsed by `JSON.parse` — not a media decoder, and not a parser with a
      # history of memory-safety bugs. The question that decides whether recycling a worker is safe is whether a
      # malicious input can execute in this process, and through ffprobe's JSON it cannot. Reading a tool's
      # *output file* with an in-process media library is in-process decoding; parsing its structured stdout with
      # the standard library is not.
      #
      # The result is a superset of what either analyzer writes, and the client analyzers slice it to Rails'
      # exact keys — the same split the image analyzer uses. Two things here are deliberately not Rails. Every
      # number is coerced tolerantly rather than with `Integer()`/`Float()` that raise, because ffprobe's output
      # is attacker-controlled where Rails' is trusted; a value that is not a clean number is dropped rather than
      # crashing the analysis. And `tags` — title, artist, arbitrary bytes that need not be valid UTF-8 — are
      # never returned, where Rails writes them straight into the database.
      class ProbeMediaOperation < ToolOperation
        operation "active_storage.probe_media"

        limits deadline: 30, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 128

        ROTATIONS = [ 90, 270, -90, -270 ].freeze

        def perform(inputs, _outputs)
          source, = inputs
          probed = JSON.parse(run!("ffprobe", "-v", "quiet", "-print_format", "json",
                                   "-show_format", "-show_streams", source.fd_path,
                                   pass: [ source.to_io ]).out)

          video = stream_of(probed, "video")
          audio = stream_of(probed, "audio")

          { duration: duration(probed, video, audio), bytes: source.to_io.stat.size,
            video: !video.nil?, audio: !audio.nil? }
            .merge(video ? video_metadata(video) : {})
            .merge(audio ? audio_metadata(audio) : {})
            .compact
        rescue JSON::ParserError => error
          raise UnreadableDocument, "ffprobe said something that is not JSON: #{error.message[0, 120]}"
        end

        private
          def stream_of(probed, type)
            Array(probed["streams"]).find { |stream| stream["codec_type"] == type }
          end

          def duration(probed, video, audio)
            source = if video
              video["duration"] || probed.dig("format", "duration")
            elsif audio
              audio["duration"]
            end

            float(source)
          end

          # Rails' width and height: the encoded width, and a height recomputed from the display aspect ratio
          # so an anamorphic stream reports its displayed shape rather than its stored one — width-preserving,
          # the way VideoAnalyzer does it. Swapped when the stream is stored rotated a quarter turn.
          def video_metadata(stream)
            encoded_width = float(stream["width"])
            encoded_height = float(stream["height"])
            ratio = display_aspect_ratio(stream)
            displayed_height = computed_height(encoded_width, ratio) || encoded_height
            angle = angle(stream)
            rotated = ROTATIONS.include?(angle)

            { width: rotated ? displayed_height : encoded_width,
              height: rotated ? encoded_width : displayed_height,
              angle: angle, display_aspect_ratio: ratio,
              video_codec: SCRUB[stream["codec_name"]] }
          end

          def audio_metadata(stream)
            { sample_rate: integer(stream["sample_rate"]), bit_rate: integer(stream["bit_rate"]),
              audio_codec: SCRUB[stream["codec_name"]] }
          end

          def computed_height(encoded_width, ratio)
            return nil unless encoded_width && ratio

            encoded_width * (ratio.last.to_f / ratio.first)
          end

          def display_aspect_ratio(stream)
            descriptor = stream["display_aspect_ratio"].to_s
            numerator, denominator = descriptor.split(":", 2).map { |term| integer(term) }
            [ numerator, denominator ] if numerator&.positive? && denominator&.positive?
          end

          # The angle Rails reports: a rotate tag first, then a Display Matrix side-data entry. Anything that
          # is not a clean integer is nothing, because this rides untrusted ffprobe output.
          def angle(stream)
            tags = stream["tags"] || {}
            return integer(tags["rotate"]) if tags["rotate"]

            matrix = Array(stream["side_data_list"]).find { |data| data["side_data_type"] == "Display Matrix" }
            integer(matrix["rotation"]) if matrix
          end

          # Numbers, and codec names matched against a conservative pattern. A tag or a codec that is not one
          # of these is dropped rather than carried into a database as arbitrary bytes.
          CODEC = /\A[a-z0-9_]{1,32}\z/
          SCRUB = ->(value) { value.to_s.match?(CODEC) ? value.to_s : nil }

          def integer(value)
            number = float(value)
            number&.to_i
          end

          def float(value)
            return nil if value.nil?

            parsed = Float(value, exception: false)
            parsed if parsed&.finite?
          end
      end
    end
  end
end
