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
