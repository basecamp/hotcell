# frozen_string_literal: true

require "test_helper"

class MediaAnalyzerTest < ActiveStorageHotCellClientTest
  Video = ActiveStorage::HotCell::Client::Analyzers::Video::Ffprobe
  Audio = ActiveStorage::HotCell::Client::Analyzers::Audio::Ffprobe

  def test_the_video_analyzer_accepts_video_and_nothing_else
    assert Video.accept?(Blob.new(fixture("sample.mp4")))
    refute Video.accept?(Blob.new(fixture("sample.mp3")))
    refute Video.accept?(Blob.new(fixture("colour.png")))
  end

  def test_the_audio_analyzer_accepts_audio_and_nothing_else
    assert Audio.accept?(Blob.new(fixture("sample.mp3")))
    refute Audio.accept?(Blob.new(fixture("sample.mp4")))
  end

  # Exactly Rails' VideoAnalyzer keys, and nothing the cell knows on top of them.
  def test_the_video_analyzer_returns_rails_video_metadata
    with_cell do
      metadata = Video.new(Blob.new(fixture("sample.mp4"))).metadata

      assert_in_delta 64.0, metadata[:width], 0.01
      assert_in_delta 48.0, metadata[:height], 0.01
      assert_equal [ 4, 3 ], metadata[:display_aspect_ratio]
      assert_equal true, metadata[:video]
      assert_equal false, metadata[:audio]
      assert_in_delta 1.0, metadata[:duration], 0.2
      assert_equal %i[ width height duration display_aspect_ratio video audio ].sort, metadata.keys.sort
    end
  end

  # `config.active_storage.ffprobe_arguments` is a shell string an application already sets for the in-process
  # analyzer, and it must mean the same thing here: split the way Rails splits it, carried in the request, and
  # spliced by the cell before the input. Excluding the fixture's own codec is the proof, because a whitelist
  # that never reached ffprobe would leave the analysis returning dimensions as it does above.
  def test_ffprobe_arguments_reach_the_cell_split_the_way_rails_splits_them
    with_ffprobe_arguments "-codec_whitelist aac" do
      with_cell do
        assert_equal({}, Video.new(Blob.new(fixture("sample.mp4"))).metadata)
      end
    end
  end

  # An application that leaves `config.active_storage.ffmpeg_allowed_formats` at Rails' default sends no
  # `formats`, because a cell that predates the keyword answers `failed` to it, and the cell's own default is
  # the same list.
  def test_the_default_allowed_formats_are_not_sent
    [ ActiveStorage.ffmpeg_allowed_formats, ActiveStorage.ffmpeg_allowed_formats.join(",") ].each do |default|
      transport = with_canned_response failed("unreadable")

      with_active_storage_setting :ffmpeg_allowed_formats, default do
        Video.new(Blob.new(fixture("sample.mp4"))).metadata
      end

      refute JSON.parse(transport.lines.last).fetch("payload", {}).key?("formats"), "sent #{default.inspect}"
    end
  end

  # Rails' outcome for a file in a format outside the list: no metadata, and a warning in the log.
  def test_a_format_outside_the_allowed_formats_is_marked_analyzed_with_a_warning
    log = StringIO.new

    with_active_storage_setting :logger, Logger.new(log) do
      with_cell do
        assert_equal({}, Video.new(Blob.new(fixture("sample.mxf"))).metadata)
      end
    end

    assert_match "sample.mxf could not be analyzed", log.string
  end

  def test_allowed_formats_reach_the_cell
    with_active_storage_setting :ffmpeg_allowed_formats, %w[ mxf ] do
      with_cell do
        assert_in_delta 64.0, Video.new(Blob.new(fixture("sample.mxf"))).metadata[:width], 0.01
        assert_equal({}, Video.new(Blob.new(fixture("sample.mp4"))).metadata)
      end
    end
  end

  # Rails joins the setting with commas, so a comma-separated string works there and has to work here.
  def test_allowed_formats_given_as_a_comma_separated_string_reach_the_cell
    with_active_storage_setting :ffmpeg_allowed_formats, "matroska,mxf" do
      with_cell do
        assert_in_delta 64.0, Video.new(Blob.new(fixture("sample.mxf"))).metadata[:width], 0.01
      end
    end
  end

  def test_nil_allowed_formats_let_the_cell_open_any_format
    with_active_storage_setting :ffmpeg_allowed_formats, nil do
      with_cell do
        assert_in_delta 64.0, Video.new(Blob.new(fixture("sample.mxf"))).metadata[:width], 0.01
      end
    end
  end

  # Exactly Rails' AudioAnalyzer keys, minus tags.
  def test_the_audio_analyzer_returns_rails_audio_metadata_without_tags
    with_cell do
      metadata = Audio.new(Blob.new(fixture("sample.mp3"))).metadata

      assert_equal 44_100, metadata[:sample_rate]
      assert_equal 64_000, metadata[:bit_rate]
      assert_in_delta 1.0, metadata[:duration], 0.2
      refute metadata.key?(:tags)
      assert_equal %i[ duration bit_rate sample_rate ].sort, metadata.keys.sort
    end
  end

  # The permanent-versus-transient split, both directions, the way the image analyzer has it: an unreadable
  # file is marked analyzed rather than retried forever, and a cell failure leaves the blob for another try.
  def test_a_permanently_unreadable_media_file_is_marked_analyzed
    with_cell do
      assert_empty Video.new(Blob.new(fixture("broken.mp4"))).metadata
    end
  end

  def test_a_transient_failure_raises_so_the_blob_stays_unanalyzed
    with_canned_response failed("capacity")

    assert_raises TemporarilyUnavailable do
      Video.new(Blob.new(fixture("sample.mp4"))).metadata
    end
  end
end
