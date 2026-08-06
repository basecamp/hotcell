# frozen_string_literal: true

require "test_helper"

class AnalyzeImageTest < ActiveStorageHotCellTest
  def test_analysis_returns_metadata_and_no_bytes_at_all
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture("colour.png") ])).result

      assert_equal 60, result[:width]
      assert_equal 40, result[:height]
      assert_equal File.size(fixture("colour.png")), result[:bytes]
    end
  end

  # The whole orientation matrix, which is what Rails' own analyzer tests and what an off-by-one in the 5..8
  # range would show up in. Every fixture is stored 60x40; what differs is what EXIF says to do with it.
  #
  # Mirroring alone is orientation 2, which does not swap. Rotation is 6, which does. Mirrored *and* rotated is
  # 5, which does — testing only the plain rotation would miss the two that share its answer for the other
  # reason.
  ORIENTATIONS = {
    "colour.jpg" => [ 60, 40 ],            # TopLeft, stored as displayed
    "mirrored.jpg" => [ 60, 40 ],          # TopRight, flipped but not turned
    "rotated.jpg" => [ 40, 60 ],           # RightTop, turned a quarter
    "mirrored_rotated.jpg" => [ 40, 60 ],  # LeftTop, flipped and turned
  }.freeze

  def test_exif_orientation_decides_which_way_round_the_dimensions_are
    Cell.boot do |cell|
      ORIENTATIONS.each do |name, (width, height)|
        result = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture(name) ])).result

        assert_equal width, result[:width], "#{name} width"
        assert_equal height, result[:height], "#{name} height"
      end
    end
  end

  # What tells a caller whether asking to keep the animation would mean anything. Rails' analyzer does not
  # produce it; BC4's does, and this is the shape that makes it expressible.
  def test_analysis_says_how_many_frames_there_are
    Cell.boot do |cell|
      still = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture("colour.png") ])).result
      moving = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture("animated.gif") ])).result

      assert_equal 1, still[:pages]
      refute still[:animated]
      assert_equal 3, moving[:pages]
      assert moving[:animated]
    end
  end

  # The built-in vips analyzer rescues every Vips::Error and returns an empty hash, which is then merged with
  # `analyzed: true` — so an undecodable image is recorded as successfully analyzed, forever, and nothing
  # re-enqueues AnalyzeJob. This deliberately does not copy that: the cell reports the verdict and the client
  # decides, because only the client knows whether it is safe to write down.
  def test_an_undecodable_image_is_reported_rather_than_recorded_as_analyzed
    Cell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("active_storage.analyze_image",
                                                      inputs: [ fixture("broken.png") ])

      assert_equal "Vips::Error", failure.error_class
      assert_predicate failure, :terminal?
    end
  end
end
