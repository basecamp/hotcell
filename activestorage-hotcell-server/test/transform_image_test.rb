# frozen_string_literal: true

require "test_helper"

class TransformImageTest < ActiveStorageHotCellTest
  def test_a_variant_comes_back_resized
    Cell.boot do |cell|
      with_output do |destination|
        response = cell.call "active_storage.transform_image",
                             inputs: [ fixture("colour.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { resize_to_limit: [ 30, 30 ] } }

        assert_ok response
        assert_equal({ width: 30, height: 20, format: "PNG", frames: 1 }, identify(destination))
      end
    end
  end

  # A thumbnailer needs the output's own dimensions rather than the ones it asked for, and an analyzer returns
  # metadata and no bytes at all. So the result carries what the produced file actually is.
  def test_the_result_describes_what_was_produced_rather_than_what_was_asked_for
    Cell.boot do |cell|
      with_output do |destination|
        result = assert_ok(cell.call("active_storage.transform_image",
                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                     payload: { format: "webp", operations: { resize_to_limit: [ 30, 30 ] } })).result

        assert_equal 30, result[:width]
        assert_equal 20, result[:height]
        assert_equal "webp", result[:format]
        assert_equal "image/webp", result[:content_type]
        assert_equal File.size(destination), result[:bytes]
      end
    end
  end

  # The only number that says whether a cell's memory limit is sized right, since RSS understates the charge and
  # VmSize overstates it by more than twice.
  def test_every_response_reports_what_libvips_charged
    Cell.boot do |cell|
      with_output do |destination|
        result = assert_ok(cell.call("active_storage.transform_image",
                                     inputs: [ fixture("big.png") ], outputs: [ destination ],
                                     payload: { format: "png", operations: { resize_to_fill: [ 64, 64 ] } })).result

        assert_operator result[:tracked_mem_highwater], :>, 0
      end
    end
  end

  def test_a_format_change_with_no_operations_at_all
    Cell.boot do |cell|
      with_output do |destination|
        assert_ok cell.call("active_storage.transform_image", inputs: [ fixture("colour.png") ],
                                                              outputs: [ destination ], payload: { format: "jpg" })

        assert_equal "JPEG", identify(destination)[:format]
      end
    end
  end

  # `page: 0` is what Rails passes and what stops a hundred-frame GIF being decoded in full to make one
  # thumbnail. Keeping the frames is the caller's intent, expressed as intent rather than as `loader: { n: -1 }`.
  def test_an_animated_source_is_flattened_to_its_first_frame_by_default
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transform_image", inputs: [ fixture("animated.gif") ],
                                                              outputs: [ destination ], payload: { format: "gif" })

        assert_equal 1, identify(destination)[:frames]
      end
    end
  end

  def test_asking_to_keep_the_animation_keeps_every_frame
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transform_image",
                            inputs: [ fixture("animated.gif") ], outputs: [ destination ],
                            payload: { format: "gif", animated: true })

        assert_equal 3, identify(destination)[:frames]
      end
    end
  end

  # Saver options belong to the operation, and these two arrive as intent because they are already signed into
  # variant URLs that were minted years ago and never expire.
  def test_asking_for_lower_quality_produces_fewer_bytes
    Cell.boot do |cell|
      sizes = [ 90, 10 ].map do |quality|
        with_output do |destination|
          assert_ok cell.call("active_storage.transform_image",
                              inputs: [ fixture("big.png") ], outputs: [ destination ],
                              payload: { format: "jpg", quality: quality })
          File.size(destination)
        end
      end

      assert_operator sizes.last, :<, sizes.first
    end
  end

  def test_a_quality_outside_the_range_is_a_caller_bug_rather_than_a_bad_document
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transform_image",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "jpg", quality: 0 })

        assert_match "quality 0 is not an integer between 1 and 100", failure.message
      end
    end
  end

  # The allowlist here is not a second line of defence. Rails' Transformers::Vips overrides only #processor, so
  # supported_image_processing_methods is enforced by the ImageMagick transformer alone and the vips path has no
  # allowlist at all.
  def test_an_operation_outside_the_allowlist_is_refused
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transform_image",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png", operations: { linear: [ 2, 0 ] } })

        assert_match "linear is not one of", failure.message
      end
    end
  end

  def test_a_format_outside_the_allowlist_is_refused
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transform_image",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "dzsave" })

        assert_match "is not one of", failure.message
      end
    end
  end

  # A caller bug is terminal and the client raises it. A bad document is terminal too but the client serves a
  # placeholder for it, so the two must not arrive as the same code.
  def test_a_refused_transformation_is_terminal
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transform_image",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png", operations: { system: "id" } })

        assert_predicate failure, :terminal?
      end
    end
  end

  def test_something_that_is_not_an_image_is_unreadable_rather_than_failed
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.transform_image",
                                                        inputs: [ fixture("broken.png") ], outputs: [ destination ],
                                                        payload: { format: "png" })

        assert_equal "Vips::Error", failure.error_class
        assert_predicate failure, :terminal?
      end
    end
  end

  def test_the_cell_carries_the_operations_and_says_so
    Cell.boot do |cell|
      described = cell.connect("control.sock") do |connection|
        connection.send_message HotCell::Request.new(op: HotCell::DESCRIBE).to_line
        cell.answer connection
      end

      assert_includes assert_ok(described).result[:operations], "active_storage.transform_image"
    end
  end
end
