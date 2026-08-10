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
  # thumbnail.
  def test_an_animated_source_is_flattened_to_its_first_frame_by_default
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transform_image", inputs: [ fixture("animated.gif") ],
                                                              outputs: [ destination ], payload: { format: "gif" })

        assert_equal 1, identify(destination)[:frames]
      end
    end
  end

  # A caller's own loader merges over the `page: 0` above, which is how Rails composes them too.
  def test_a_loader_asking_for_every_frame_keeps_every_frame
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transform_image",
                            inputs: [ fixture("animated.gif") ], outputs: [ destination ],
                            payload: { format: "gif", operations: { loader: { n: -1 } } })

        assert_equal 3, identify(destination)[:frames]
      end
    end
  end

  # Saver options reach ImageProcessing as Rails passes them. Bounding what may appear inside them is a planned
  # feature; until then this is Rails' behaviour, inside the sandbox.
  def test_a_saver_reaches_the_encoder
    Cell.boot do |cell|
      sizes = [ 90, 10 ].map do |quality|
        with_output do |destination|
          assert_ok cell.call("active_storage.transform_image",
                              inputs: [ fixture("big.png") ], outputs: [ destination ],
                              payload: { format: "jpg", operations: { saver: { Q: quality } } })
          File.size(destination)
        end
      end

      assert_operator sizes.last, :<, sizes.first
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

  # A caller bug is permanent and the client raises it. A bad document is permanent too but the client serves a
  # placeholder for it, so the two must not arrive as the same code.
  def test_a_refused_transformation_is_permanent
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transform_image",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png", operations: { system: "id" } })

        assert_predicate failure, :permanent?
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
        assert_predicate failure, :permanent?
      end
    end
  end

  # The exact set rather than one of them. This gem defines two abstract base classes, VipsOperation and
  # ConverterOperation, and an operation registers by existing — so an assertion that only looked for what
  # should be here would not notice two more that should not.
  def test_the_cell_carries_the_operations_and_says_so
    Cell.boot do |cell|
      described = cell.connect("control.sock") do |connection|
        connection.send_message HotCell::Request.new(op: HotCell::DESCRIBE).to_line
        cell.answer connection
      end

      assert_equal %w[ active_storage.analyze_image active_storage.preview_pdf active_storage.preview_video
                       active_storage.probe_media active_storage.transform_image ],
                   assert_ok(described).result[:operations]
    end
  end
end
