# frozen_string_literal: true

require "json"
require "active_storage/hot_cell/converter_operation"

module ActiveStorage
  module HotCell
    # What Rails' video and audio analyzers do, moved out of the application: ffprobe, and a small set of numbers
    # taken out of what it says.
    #
    # **This reads its converter's stdout, and it is still `:subprocess`. That is a judgement, so here it is.**
    #
    # ffprobe parses the media in an exec'd child that dies at the end of the call. What comes back into this
    # worker is JSON on a bounded buffer, parsed by `JSON.parse` — not a media decoder, and not a parser with a
    # history of memory-safety bugs. Treating that as equivalent to decoding an image in-process would make the
    # `:in_process` declaration mean "touches any attacker-influenced byte", which is every operation, and a
    # distinction that covers everything guides nobody.
    #
    # What the declaration is actually for is deciding whether recycling a worker is safe, and the question it
    # asks is whether a malicious input can execute in this process. Through ffprobe's JSON it cannot.
    #
    # This is the line, and it is worth stating so the next operation can be judged against it: reading a
    # converter's *output file* with an in-process media library is `:in_process`, because that is a decoder
    # running on bytes a converter just produced from a hostile document. Parsing a converter's structured
    # stdout with the standard library is not.
    class ProbeMedia < ConverterOperation
      operation "active_storage.probe_media"

      limits deadline: 30, memory: 1024 * 1024**2, file_size: 48 * 1024**2, open_files: 128

      # Numbers, and codec names matched against a conservative pattern. Nothing else comes back.
      #
      # Everything ffprobe reports about a file is attacker-controlled, including title and artist tags, which
      # arrive as arbitrary bytes that may not even be valid UTF-8. Passing that through would put a hostile
      # string into an application's database via a response that is supposed to carry facts about pixels.
      CODEC = /\A[a-z0-9_]{1,32}\z/
      SCRUB = ->(value) { value.to_s.match?(CODEC) ? value.to_s : nil }

      def perform(inputs, _outputs, _payload)
        source, = inputs
        probed = JSON.parse(run!("ffprobe", "-v", "quiet", "-print_format", "json",
                                 "-show_format", "-show_streams", source.path).out)

        video = stream_of(probed, "video")
        audio = stream_of(probed, "audio")

        { duration: number(probed.dig("format", "duration")),
          bytes: File.size(source.path) }
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

        # Display aspect ratio, not the coded one: a video stored 720x480 with a 16:9 aspect ratio is displayed
        # as 853x480, and Rails' own analyzer corrects for exactly this.
        def video_metadata(stream)
          width, height = displayed(stream)

          { width: width, height: height, video_codec: SCRUB[stream["codec_name"]],
            rotation: number(stream.dig("side_data_list", 0, "rotation")) }
        end

        def audio_metadata(stream)
          { audio: true, audio_codec: SCRUB[stream["codec_name"]],
            sample_rate: number(stream["sample_rate"]) }
        end

        def displayed(stream)
          width, height = number(stream["width"]), number(stream["height"])
          return [ width, height ] unless width && height

          numerator, denominator = stream["display_aspect_ratio"].to_s.split(":").map { |part| number(part) }
          return [ width, height ] unless numerator&.positive? && denominator&.positive?

          [ (height * numerator.fdiv(denominator)).round, height ]
        end

        def number(value)
          return nil if value.nil?

          float = Float(value, exception: false)
          return nil if float.nil? || !float.finite?

          float == float.to_i ? float.to_i : float
        end
    end
  end
end
