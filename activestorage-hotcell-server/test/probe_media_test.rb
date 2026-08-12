# frozen_string_literal: true

require "test_helper"

class ProbeMediaTest < ActiveStorageHotCellTest
  def test_probing_a_video_returns_its_shape
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.probe_media", inputs: [ fixture("sample.mp4") ])).result

      assert_equal 64, result[:width]
      assert_equal 48, result[:height]
      assert_equal "h264", result[:video_codec]
      assert_in_delta 1.0, result[:duration], 0.2
      assert_equal File.size(fixture("sample.mp4")), result[:bytes]
    end
  end

  def test_a_file_with_no_audio_says_nothing_about_audio
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.probe_media", inputs: [ fixture("sample.mp4") ])).result

      refute result.key?(:audio)
      refute result.key?(:audio_codec)
    end
  end

  def test_probing_audio_returns_its_codec_and_sample_rate_and_no_dimensions
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.probe_media", inputs: [ fixture("sample.mp3") ])).result

      assert result[:audio]
      assert_equal "mp3", result[:audio_codec]
      assert_equal 44_100, result[:sample_rate]
      assert_in_delta 1.0, result[:duration], 0.2
      refute result.key?(:width)
      refute result.key?(:height)
    end
  end

  # ffprobe reads the input through a passed descriptor, not a scratch copy, so probing is not bounded by
  # file_size — the write limit. A media file larger than that limit is probed rather than killed while
  # being staged. This exercises the same run_tool descriptor passing that both previewers use.
  def test_an_input_larger_than_the_write_limit_is_still_probed
    Cell.boot(file_size: 4 * 1024) do |cell|
      result = assert_ok(cell.call("active_storage.probe_media", inputs: [ fixture("sample.mp3") ])).result

      assert result[:audio]
      assert_equal "mp3", result[:audio_codec]
    end
  end

  def test_something_that_is_not_media_is_unreadable
    Cell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("active_storage.probe_media",
                                                      inputs: [ fixture("broken.mp4") ])

      assert_predicate failure, :permanent?
    end
  end

  # Everything ffprobe reports is attacker-controlled, including title and artist tags, which arrive as arbitrary
  # bytes that need not be valid UTF-8. Only numbers and codec names matching a conservative pattern come back,
  # so a hostile string cannot ride a response that is supposed to carry facts about pixels into a database.
  CODEC = /\A[a-z0-9_]{1,32}\z/

  def test_only_numbers_and_recognisable_codec_names_come_back
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.probe_media", inputs: [ fixture("sample.mp4") ])).result

      result.each do |key, value|
        assert value.is_a?(Numeric) || value == true || value.to_s.match?(CODEC),
               "#{key} came back as #{value.inspect}, which is neither a number nor a codec name"
      end
    end
  end
end
