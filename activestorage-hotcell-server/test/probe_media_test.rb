# frozen_string_literal: true

require "test_helper"

class ProbeMediaTest < ActiveStorageHotCellTest
  def test_probing_a_video_returns_the_shape_rails_records
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyzers.media.ffprobe", inputs: [ fixture("sample.mp4") ])).result

      assert_in_delta 64.0, result[:width], 0.01
      assert_in_delta 48.0, result[:height], 0.01
      assert_equal [ 4, 3 ], result[:display_aspect_ratio]
      assert result[:video]
      refute result[:audio]
      assert_in_delta 1.0, result[:duration], 0.2
      assert_equal File.size(fixture("sample.mp4")), result[:bytes]
    end
  end

  # Rails reports dimensions as floats, and a stream with no rotation carries no angle at all.
  def test_dimensions_are_floats_and_an_unrotated_video_reports_no_angle
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyzers.media.ffprobe", inputs: [ fixture("sample.mp4") ])).result

      assert_kind_of Float, result[:width]
      refute result.key?(:angle)
    end
  end

  def test_probing_audio_returns_the_shape_rails_records
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyzers.media.ffprobe", inputs: [ fixture("sample.mp3") ])).result

      assert result[:audio]
      refute result[:video]
      assert_equal 44_100, result[:sample_rate]
      assert_equal 64_000, result[:bit_rate]
      assert_in_delta 1.0, result[:duration], 0.2
      refute result.key?(:width)
    end
  end

  # ffprobe reads the input through a passed descriptor, not a scratch copy, so probing is not bounded by
  # file_size — the write limit. A media file larger than that limit is probed rather than killed while
  # being staged. This exercises the same run_tool descriptor passing that both previewers use.
  def test_an_input_larger_than_the_write_limit_is_still_probed
    Cell.boot(file_size: 4 * 1024) do |cell|
      result = assert_ok(cell.call("active_storage.analyzers.media.ffprobe", inputs: [ fixture("sample.mp3") ])).result

      assert result[:audio]
      assert_equal 44_100, result[:sample_rate]
    end
  end

  def test_something_that_is_not_media_is_unreadable
    Cell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("active_storage.analyzers.media.ffprobe",
                                                      inputs: [ fixture("broken.mp4") ])

      assert_predicate failure, :permanent?
    end
  end

  # Everything ffprobe reports is attacker-controlled, and a title or artist tag arrives as arbitrary bytes.
  # Only numbers and codec names come back, so a hostile string cannot ride a response about pixels into a
  # database. `tags`, which Rails stores raw, are never returned.
  CODEC = /\A[a-z0-9_]{1,32}\z/

  def test_only_numbers_and_recognisable_codec_names_come_back
    Cell.boot do |cell|
      [ "sample.mp4", "sample.mp3" ].each do |name|
        result = assert_ok(cell.call("active_storage.analyzers.media.ffprobe", inputs: [ fixture(name) ])).result

        refute result.key?(:tags)
        result.each do |key, value|
          assert value.is_a?(Numeric) || value == true || value == false ||
                 (value.is_a?(Array) && value.all?(Integer)) || value.to_s.match?(CODEC),
                 "#{key} came back as #{value.inspect}, which is neither a number nor a codec name"
        end
      end
    end
  end
end
