# frozen_string_literal: true

require "test_helper"
require "active_storage/hot_cell/server/probe_media_operation"

# Everything ffprobe reports about a file is attacker-controlled, and these are the functions that stand
# between its output and an application's database. They are exercised directly with hostile shapes, because
# no fixture can make ffprobe emit them — a real cell round-trip only ever shows the shaping on honest files.
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
      assert_nil operation.send(:integer, hostile), "#{hostile.inspect} should not have come back"
    end
  end

  def test_integers_and_floats_coerce_the_way_rails_reports_them
    assert_equal 44_100, operation.send(:integer, "44100")
    assert_in_delta 1.5, operation.send(:float, "1.5"), 0.001
    assert_kind_of Float, operation.send(:float, "48")
  end

  def test_a_hostile_aspect_ratio_is_dropped_rather_than_believed
    [ "0:9", "16:0", "-16:9", "banana", "16", "16:9:4", nil ].each do |hostile|
      stream = { "width" => 720, "height" => 480, "display_aspect_ratio" => hostile }

      assert_nil operation.send(:video_metadata, stream)[:display_aspect_ratio],
                 "#{hostile.inspect} should not have become an aspect ratio"
    end
  end

  # A hostile aspect ratio drops out, so the encoded dimensions stand rather than being scaled by nonsense.
  def test_a_hostile_aspect_ratio_leaves_the_encoded_dimensions_standing
    stream = { "width" => 720, "height" => 480, "display_aspect_ratio" => "banana" }
    metadata = operation.send(:video_metadata, stream)

    assert_in_delta 720.0, metadata[:width], 0.01
    assert_in_delta 480.0, metadata[:height], 0.01
  end

  # Rails' anamorphic correction: an honest aspect ratio recomputes the height, width-preserving.
  def test_an_honest_aspect_ratio_recomputes_the_height_width_preserving
    stream = { "width" => 720, "height" => 480, "display_aspect_ratio" => "16:9" }
    metadata = operation.send(:video_metadata, stream)

    assert_in_delta 720.0, metadata[:width], 0.01
    assert_in_delta 405.0, metadata[:height], 0.01
  end

  def test_a_quarter_turn_swaps_the_reported_dimensions
    stream = { "width" => 1920, "height" => 1080, "display_aspect_ratio" => "16:9",
               "tags" => { "rotate" => "90" } }
    metadata = operation.send(:video_metadata, stream)

    assert_in_delta 1080.0, metadata[:width], 0.01
    assert_in_delta 1920.0, metadata[:height], 0.01
    assert_equal 90, metadata[:angle]
  end

  def test_the_rotate_tag_wins_and_the_display_matrix_is_the_fallback
    tagged = { "tags" => { "rotate" => "270" },
               "side_data_list" => [ { "side_data_type" => "Display Matrix", "rotation" => -90 } ] }
    matrixed = { "side_data_list" => [ { "side_data_type" => "Display Matrix", "rotation" => -90 } ] }

    assert_equal 270, operation.send(:angle, tagged)
    assert_equal(-90, operation.send(:angle, matrixed))
    assert_nil operation.send(:angle, { "tags" => { "rotate" => "sideways" } })
  end

  private
    def operation
      OPERATION.new
    end
end
