# Handing back whatever ffprobe said, including title and artist tags, which are attacker-controlled strings on
# their way into an application's database.
require "active_storage/hot_cell/server/probe_media"
module ActiveStorage
  module HotCell
    module Server
      class ProbeMedia
        def perform(inputs, _outputs, _payload)
          probed = JSON.parse(run!("ffprobe", "-v", "quiet", "-print_format", "json", "-show_format",
                                   "-show_streams", inputs.first.path).out)
          stream = Array(probed["streams"]).find { |s| s["codec_type"] == "video" } || {}
          { width: stream["width"], height: stream["height"], video_codec: stream["codec_name"],
            tags: probed.dig("format", "tags"), bytes: File.size(inputs.first.path) }.compact
        end
      end
    end
  end
end
