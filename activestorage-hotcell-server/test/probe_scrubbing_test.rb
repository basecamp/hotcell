# frozen_string_literal: true

require "test_helper"
require "active_storage/hot_cell/server/probe_media_operation"

# Everything ffprobe reports about a file is attacker-controlled, and these are the functions that stand
# between its output and an application's database. They are exercised directly with hostile shapes,
# because no fixture can make ffprobe emit them — a real cell round-trip only ever shows the scrubbing
# facts about honest files.
class ProbeScrubbingTest < ActiveStorageHotCellTest
  OPERATION = ActiveStorage::HotCell::Server::ProbeMediaOperation

  def test_a_codec_name_that_is_not_a_codec_name_is_dropped
    [ "h264; rm -rf /", "H264", "a" * 33, "", "mp3\n", "<script>", nil ].each do |hostile|
      assert_nil OPERATION::SCRUB[hostile], "#{hostile.inspect} should not have come back"
    end
  end

  def test_a_recognisable_codec_name_survives
    [ "h264", "mp3", "aac", "pcm_s16le", "vp9" ].each do |codec|
      assert_equal codec, OPERATION::SCRUB[codec]
    end
  end

  def test_numbers_that_are_not_numbers_are_dropped
    [ "NaN", "Infinity", "-Infinity", "12px", "", nil, "12; rm -rf /" ].each do |hostile|
      assert_nil operation.send(:number, hostile), "#{hostile.inspect} should not have come back"
    end
  end

  def test_numbers_come_back_as_the_narrowest_type
    assert_equal 3, operation.send(:number, "3.0")
    assert_equal 2.5, operation.send(:number, "2.5")
    assert_equal 44_100, operation.send(:number, "44100")
  end

  def test_a_hostile_aspect_ratio_leaves_the_stored_dimensions_standing
    [ "0:9", "16:0", "-16:9", "banana", "16", nil ].each do |hostile|
      stream = { "width" => 720, "height" => 480, "display_aspect_ratio" => hostile }

      assert_equal [ 720, 480 ], operation.send(:displayed, stream),
                   "#{hostile.inspect} should not have changed the dimensions"
    end
  end

  def test_an_honest_aspect_ratio_widens_the_displayed_dimensions
    stream = { "width" => 720, "height" => 480, "display_aspect_ratio" => "16:9" }

    assert_equal [ 853, 480 ], operation.send(:displayed, stream)
  end

  def test_video_metadata_carries_nothing_but_scrubbed_values
    stream = { "codec_name" => "h264\"; DROP TABLE blobs;--", "width" => "99", "height" => 66,
               "side_data_list" => [ { "rotation" => "-90" } ] }

    assert_equal({ width: 99, height: 66, video_codec: nil, rotation: -90 },
                 operation.send(:video_metadata, stream))
  end

  private
    def operation
      OPERATION.new
    end
end
