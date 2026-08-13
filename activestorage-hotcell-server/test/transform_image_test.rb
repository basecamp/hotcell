# frozen_string_literal: true

require "test_helper"

class TransformImageTest < ActiveStorageHotCellTest
  def test_a_variant_comes_back_resized
    Cell.boot do |cell|
      with_output do |destination|
        response = cell.call "active_storage.transformers.image.vips",
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
        result = assert_ok(cell.call("active_storage.transformers.image.vips",
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
        result = assert_ok(cell.call("active_storage.transformers.image.vips",
                                     inputs: [ fixture("big.png") ], outputs: [ destination ],
                                     payload: { format: "png", operations: { resize_to_fill: [ 64, 64 ] } })).result

        assert_operator result[:tracked_mem_highwater], :>, 0
      end
    end
  end

  def test_a_format_change_with_no_operations_at_all
    Cell.boot do |cell|
      with_output do |destination|
        assert_ok cell.call("active_storage.transformers.image.vips", inputs: [ fixture("colour.png") ],
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
        assert_ok cell.call("active_storage.transformers.image.vips", inputs: [ fixture("animated.gif") ],
                                                              outputs: [ destination ], payload: { format: "gif" })

        assert_equal 1, identify(destination)[:frames]
      end
    end
  end

  # A caller's own loader merges over the `page: 0` above, which is how Rails composes them too.
  def test_a_loader_asking_for_every_frame_keeps_every_frame
    Cell.boot do |cell|
      with_output(".gif") do |destination|
        assert_ok cell.call("active_storage.transformers.image.vips",
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
          assert_ok cell.call("active_storage.transformers.image.vips",
                              inputs: [ fixture("big.png") ], outputs: [ destination ],
                              payload: { format: "jpg", operations: { saver: { Q: quality } } })
          File.size(destination)
        end
      end

      assert_operator sizes.last, :<, sizes.first
    end
  end

  # Rails' vips path second-guesses nothing but combine_options, so neither does the cell: any
  # ImageProcessing or Vips::Image method a caller names runs. An operation allowlist is a planned, separate
  # deliverable.
  def test_a_transformation_rails_accepts_is_not_second_guessed
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.vips",
                             inputs: [ fixture("colour.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { linear: [ 2, 0 ] } }

        assert_ok response
        assert_operator File.size(destination), :>, 0
      end
    end
  end

  # The one thing Rails' vips path refuses, refused the same way. It can never become a single vips
  # pipeline, and Rails raises on it by name.
  def test_combine_options_is_refused_like_rails_refuses_it
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transformers.image.vips",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png",
                                                                operations: { combine_options: { resize: "50x50" } } })

        assert_predicate failure, :permanent?
        assert_match "combine_options", failure.message
      end
    end
  end

  # Rails drops a transformation whose argument is blank — nil, false, "", [], {} all mean "skip this
  # operation" — so a blank must not reach ImageProcessing, where it raises.
  def test_a_blank_argument_skips_the_operation_rather_than_failing
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.vips",
                             inputs: [ fixture("colour.png") ], outputs: [ destination ],
                             payload: { format: "png",
                                        operations: { resize_to_limit: [ 30, 30 ], sharpen: "",
                                                      rotate: [], flip: nil, autorot: false } }

        assert_ok response
        assert_equal 30, identify(destination)[:width]
      end
    end
  end

  # An Array here would filter to nothing and succeed as a bare format conversion, so a caller bug would
  # come back `ok` with an untransformed image instead of the permanent `invalid` that reaches a reporter.
  def test_operations_that_are_not_an_object_are_refused
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.transformers.image.vips",
                                                     inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                     payload: { format: "png",
                                                                operations: [ "resize_to_limit" ] })

        assert_predicate failure, :permanent?
        assert_match "operations must be an object", failure.message
      end
    end
  end

  # The format is decided by the vips build's savers, the way Rails decides it: Variation validates the
  # extension app-side, and a format no saver answers to raises Vips::Error at save. The classification is
  # the cell's own — Vips::Error is `unreadable` here where Rails surfaces it unclassified.
  def test_a_format_no_saver_answers_to_is_a_vips_error
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.transformers.image.vips",
                                                        inputs: [ fixture("colour.png") ],
                                                        outputs: [ destination ],
                                                        payload: { format: "xyzzy" })

        assert_equal "Vips::Error", failure.error_class
      end
    end
  end

  # A name that is neither an ImageProcessing operation nor a Vips::Image method is refused by
  # ImageProcessing itself, exactly as it is under Rails on vips. It arrives `failed` — transient — so a
  # caller bug is never written down against the document.
  def test_an_unknown_transformation_is_not_a_verdict_on_the_document
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "failed", cell.call("active_storage.transformers.image.vips",
                                                    inputs: [ fixture("colour.png") ], outputs: [ destination ],
                                                    payload: { format: "png", operations: { system: "id" } })

        refute_predicate failure, :permanent?
        assert_match "system", failure.message
      end
    end
  end

  # The input is read through its descriptor, not staged, so its size is not bounded by file_size — which
  # bounds only what the operation writes. A large source downscaled to a small thumbnail succeeds under a
  # file_size that the source alone would have blown while being copied onto scratch.
  def test_a_large_source_downscaled_to_a_small_thumbnail_is_not_bounded_by_the_write_limit
    Cell.boot(file_size: 64 * 1024) do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.transformers.image.vips",
                             inputs: [ fixture("large.png") ], outputs: [ destination ],
                             payload: { format: "png", operations: { resize_to_limit: [ 32, 32 ] } }

        assert_ok response
        assert_equal 32, identify(destination)[:width]
      end
    end
  end

  def test_something_that_is_not_an_image_is_unreadable_rather_than_failed
    Cell.boot do |cell|
      with_output do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.transformers.image.vips",
                                                        inputs: [ fixture("broken.png") ], outputs: [ destination ],
                                                        payload: { format: "png" })

        assert_equal "Vips::Error", failure.error_class
        assert_predicate failure, :permanent?
      end
    end
  end

  # The exact set rather than one of them. This gem defines two abstract base classes, VipsOperation and
  # ToolOperation, and an operation registers by existing — so an assertion that only looked for what
  # should be here would not notice two more that should not.
  def test_the_cell_carries_the_operations_and_says_so
    Cell.boot do |cell|
      described = cell.connect("control.sock") do |connection|
        connection.send_message HotCell::Request.new(op: HotCell::DESCRIBE).to_line
        cell.answer connection
      end

      assert_equal %w[ active_storage.analyzers.image.magick active_storage.analyzers.image.vips
                       active_storage.analyzers.media.ffprobe
                       active_storage.previewers.pdf.mutool active_storage.previewers.pdf.poppler
                       active_storage.previewers.video.ffmpeg
                       active_storage.transformers.image.magick active_storage.transformers.image.vips ],
                   assert_ok(described).result[:operations]
    end
  end
end
