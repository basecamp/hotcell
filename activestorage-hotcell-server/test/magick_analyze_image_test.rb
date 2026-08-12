# frozen_string_literal: true

require "test_helper"

# The ImageMagick image analyzer is the mini_magick sibling of the vips one: width and height from identify,
# swapped when the stored orientation is a quarter turn.
class MagickAnalyzeImageTest < ActiveStorageHotCellTest
  def test_analysis_returns_dimensions
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyze_image_imagemagick",
                                   inputs: [ fixture("colour.png") ])).result

      assert_equal 60, result[:width]
      assert_equal 40, result[:height]
      assert_equal File.size(fixture("colour.png")), result[:bytes]
    end
  end

  def test_exif_orientation_decides_which_way_round_the_dimensions_are
    Cell.boot do |cell|
      result = assert_ok(cell.call("active_storage.analyze_image_imagemagick",
                                   inputs: [ fixture("rotated.jpg") ])).result

      assert_equal 40, result[:width]
      assert_equal 60, result[:height]
    end
  end

  def test_something_that_is_not_an_image_is_unreadable
    Cell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("active_storage.analyze_image_imagemagick",
                                                      inputs: [ fixture("broken.png") ])

      assert_predicate failure, :permanent?
    end
  end
end
