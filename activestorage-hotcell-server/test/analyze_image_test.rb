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

  # EXIF says the pixels are stored rotated, so the dimensions a caller cares about are the other way round.
  # Rails' own analyzer swaps for the same orientations, and this fixture is a 60x40 JPEG tagged RightTop.
  def test_an_exif_orientation_swaps_the_dimensions
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture("rotated.jpg") ])).result

      assert_equal 40, result[:width]
      assert_equal 60, result[:height]
    end
  end

  def test_an_image_with_no_orientation_is_reported_as_stored
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyze_image", inputs: [ fixture("colour.jpg") ])).result

      assert_equal 60, result[:width]
      assert_equal 40, result[:height]
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
