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

  # The production shape that surfaced this: a multi-layer source, its frames kept by
  # `loader: { page: nil }`, into a single-layer destination. ImageProcessing refuses the
  # combination, which is a verdict on the input — unclassified it was a transient `failed`
  # that never marked the blob, so the same file spent a full conversion on every request.
  def test_a_multi_layer_source_into_a_single_layer_format_is_unreadable
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.transformers.image.magick",
                                                        inputs: [ fixture("animated.gif") ], outputs: [ destination ],
                                                        payload: { format: "jpg",
                                                                   operations: { loader: { page: nil }, resize_to_limit: [ 20, 20 ] } })

        assert_predicate failure, :permanent?
        assert_match "multi-layer", failure.message
      end
    end
  end

  # The input is read through its descriptor, not staged, so its size is not bounded by file_size — which
  # bounds only what the operation writes. A large source downscaled to a small thumbnail succeeds under a
  # file_size that the source alone would have blown while being copied onto scratch.
  def test_a_large_source_downscaled_to_a_small_thumbnail_is_not_bounded_by_the_write_limit
    Cell.boot(file_size: 64 * 1024) do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.magick",
                             inputs: [ fixture("large.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { resize_to_limit: [ 32, 32 ] } }

        assert_ok response
        assert_equal 32, identify(destination)[:width]
      end
    end
  end

  # A caller's own loader merges over the operation's, which is what Rails does — but not over how the input
  # is read. Taking `inherit_fds` out of it would leave the source naming a descriptor the tool cannot open.
  def test_a_caller_cannot_take_the_descriptor_out_of_the_loader
    Cell.boot(file_size: 64 * 1024) do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.magick",
                             inputs: [ fixture("large.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { resize_to_limit: [ 32, 32 ],
                                                                     loader: { inherit_fds: [] } } }

        assert_ok response
        assert_equal 32, identify(destination)[:width]
      end
    end
  end

  # `page: 0` reaches ImageProcessing alongside the descriptor rather than instead of it, and it is what stops
  # a hundred-frame GIF being decoded in full to make one thumbnail.
  def test_an_animated_source_is_flattened_to_its_first_frame_by_default
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transformers.image.magick",
                            inputs: [ fixture("animated.gif") ], outputs: [ destination ],
                            payload: { format: "gif" })

        assert_equal 1, identify(destination)[:frames]
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
