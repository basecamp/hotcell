# frozen_string_literal: true

require "test_helper"

# The ImageMagick transform is the mini_magick sibling of the vips one, for an application whose variants
# are ImageMagick-shaped. It runs the same source/loader/convert/apply pipeline through
# ImageProcessing::MiniMagick.
class MagickTransformImageTest < ActiveStorageHotCellTest
  def test_a_variant_comes_back_resized
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.magick",
                             inputs: [ fixture("colour.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { resize_to_limit: [ 20, 20 ] } }

        assert_ok response
        assert_operator identify(destination)[:width], :<=, 20
        assert_equal "PNG", identify(destination)[:format]
        assert_equal "image/png", response.result[:content_type]
      end
    end
  end

  def test_a_format_change
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        response = cell.call "active_storage.transformers.image.magick",
                             inputs: [ fixture("colour.png") ], outputs: [ destination ],
                             payload: { format: "jpg" }

        assert_ok response
        assert_equal "JPEG", identify(destination)[:format]
      end
    end
  end

  # An ImageMagick shape the vips path cannot run: coalesce is a real ImageMagick operation. This is the
  # whole reason the ImageMagick operations exist.
  def test_an_imagemagick_only_operation_runs
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        response = cell.call "active_storage.transformers.image.magick",
                             inputs: [ fixture("animated.gif") ], outputs: [ destination ],
                             payload: { format: "gif", operations: { coalesce: true, resize_to_limit: [ 20, 20 ] } }

        assert_ok response
        assert_equal "GIF", identify(destination)[:format]
      end
    end
  end

  def test_combine_options_is_refused
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transformers.image.magick",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png",
                                                                operations: { combine_options: { resize: "5x5" } } })

        assert_match "combine_options", failure.message
      end
    end
  end

  def test_something_that_is_not_an_image_is_unreadable
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.transformers.image.magick",
                                                        inputs: [ fixture("broken.png") ], outputs: [ destination ],
                                                        payload: { format: "png" })

        assert_predicate failure, :permanent?
      end
    end
  end
end
