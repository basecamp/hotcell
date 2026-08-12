# frozen_string_literal: true

require "test_helper"

class PreviewersTest < ActiveStorageHotCellTest
  def test_a_pdf_preview_comes_back_as_a_png
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.preview_pdf",
                             inputs: [ fixture("sample.pdf") ], outputs: [ destination ]

        assert_ok response
        assert_equal "PNG", identify(destination)[:format]
        assert_equal File.size(destination), response.result[:bytes]
      end
    end
  end

  def test_a_higher_resolution_renders_more_pixels
    Cell.boot do |cell|
      sizes = [ 36, 144 ].map do |resolution|
        with_output(".png") do |destination|
          assert_ok cell.call("active_storage.preview_pdf", inputs: [ fixture("sample.pdf") ],
                                                            outputs: [ destination ],
                                                            payload: { resolution: resolution })
          identify(destination)[:width]
        end
      end

      assert_operator sizes.last, :>, sizes.first
    end
  end

  # two_page.pdf is a white page followed by a black one, so which page rendered is measurable.
  def test_the_requested_page_is_the_one_rendered
    Cell.boot do |cell|
      first, second = [ 1, 2 ].map do |page|
        with_output(".png") do |destination|
          assert_ok cell.call("active_storage.preview_pdf", inputs: [ fixture("two_page.pdf") ],
                                                            outputs: [ destination ],
                                                            payload: { page: page })
          brightness(destination)
        end
      end

      assert_operator first, :>, 0.9, "page 1 is white"
      assert_operator second, :<, 0.1, "page 2 is black"
    end
  end

  def test_a_page_out_of_bounds_is_a_caller_bug
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.preview_pdf",
                                                     inputs: [ fixture("sample.pdf") ],
                                                     outputs: [ destination ],
                                                     payload: { page: 100_001 })

        assert_match "page 100001 must be an integer between 1 and 10000", failure.message
      end
    end
  end

  # A String would ride straight into mutool's argv, so the type check is part of the bound.
  def test_a_page_that_is_not_an_integer_is_a_caller_bug
    Cell.boot do |cell|
      with_output(".png") do |destination|
        assert_failed "invalid", cell.call("active_storage.preview_pdf",
                                           inputs: [ fixture("sample.pdf") ],
                                           outputs: [ destination ],
                                           payload: { page: "2" })
      end
    end
  end

  def test_a_nonsense_resolution_is_a_caller_bug
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.preview_pdf",
                                                     inputs: [ fixture("sample.pdf") ],
                                                     outputs: [ destination ],
                                                     payload: { resolution: 100_000 })

        assert_match "resolution 100000 must be an integer between 1 and 600", failure.message
      end
    end
  end

  def test_something_that_is_not_a_pdf_is_unreadable
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.preview_pdf",
                                                        inputs: [ fixture("broken.pdf") ],
                                                        outputs: [ destination ])

        assert_predicate failure, :permanent?
        assert_match "mutool", failure.message
      end
    end
  end

  # JPEG rather than PNG, because Rails' own video previewer yields image/jpeg and this drops into its place.
  def test_a_video_preview_comes_back_as_the_jpeg_rails_produces
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        response = cell.call "active_storage.preview_video",
                             inputs: [ fixture("sample.mp4") ], outputs: [ destination ]

        assert_ok response
        assert_equal({ width: 64, height: 48, format: "JPEG", frames: 1 }, identify(destination))
        assert_equal "image/jpeg", response.result[:content_type]
      end
    end
  end

  # ffmpeg writes the frame straight through the caller's descriptor, so the slot's output scratch is never
  # created. Proves the output is not staged and copied.
  def test_a_video_preview_is_written_through_the_descriptor_not_scratch
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        assert_ok cell.call("active_storage.preview_video", inputs: [ fixture("sample.mp4") ],
                                                            outputs: [ destination ])

        assert_operator File.size(destination), :>, 0, "the frame reached the caller's file"
        assert_empty Dir.glob(File.join(cell.workspace, "*", "scratch", "output-*")),
                     "the output was staged onto scratch instead of written directly"
      end
    end
  end

  def test_a_video_preview_can_be_taken_from_further_in
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        assert_ok cell.call("active_storage.preview_video", inputs: [ fixture("sample.mp4") ],
                                                            outputs: [ destination ], payload: { seek: 0.5 })

        assert_equal "JPEG", identify(destination)[:format]
      end
    end
  end

  # The Poppler sibling of the mutool preview, for an image that carries pdftoppm. Same result shape.
  def test_a_poppler_pdf_preview_comes_back_as_a_png
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.preview_pdf_poppler",
                             inputs: [ fixture("sample.pdf") ], outputs: [ destination ]

        assert_ok response
        assert_equal "PNG", identify(destination)[:format]
        assert_equal File.size(destination), response.result[:bytes]
      end
    end
  end

  def test_a_poppler_nonsense_resolution_is_a_caller_bug
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.preview_pdf_poppler",
                                                     inputs: [ fixture("sample.pdf") ],
                                                     outputs: [ destination ],
                                                     payload: { resolution: 100_000 })

        assert_match "resolution 100000 must be an integer between 1 and 600", failure.message
      end
    end
  end

  def test_poppler_on_something_that_is_not_a_pdf_is_unreadable
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.preview_pdf_poppler",
                                                        inputs: [ fixture("broken.pdf") ],
                                                        outputs: [ destination ])

        assert_predicate failure, :permanent?
        assert_match "pdftoppm", failure.message
      end
    end
  end

  # Rails' default preview arguments choose the first keyframe or scene change rather than the literal first
  # frame, because so many videos open on black. A drop-in replacement has to keep that choice: fade_in.mp4
  # opens on half a second of black before a hard cut, and its preview must come from after the cut.
  def test_a_video_that_opens_on_black_previews_as_the_scene_rather_than_the_black
    Cell.boot do |cell|
      with_output(".jpg") do |destination|
        assert_ok cell.call("active_storage.preview_video", inputs: [ fixture("fade_in.mp4") ],
                                                            outputs: [ destination ])

        assert_operator brightness(destination), :>, 0.1, "the preview is the black opening frame"
      end
    end
  end

  # video_preview_arguments is a shell string an application can set, and Rails splits it with Shellwords. A cell
  # exists so that nobody but the operation chooses what a tool runs, so the payload carries one number.
  def test_a_caller_cannot_choose_what_ffmpeg_runs
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "invalid", cell.call("active_storage.preview_video",
                                                     inputs: [ fixture("sample.mp4") ],
                                                     outputs: [ destination ],
                                                     payload: { seek: "0 -f lavfi -i /etc/passwd" })

        assert_match "must be a number of seconds", failure.message
      end
    end
  end

  def test_something_that_is_not_a_video_is_unreadable
    Cell.boot do |cell|
      with_output(".png") do |destination|
        failure = assert_failed "unreadable", cell.call("active_storage.preview_video",
                                                        inputs: [ fixture("broken.mp4") ],
                                                        outputs: [ destination ])

        assert_predicate failure, :permanent?
      end
    end
  end

  # This is what Rails does, not a concession. A previewer yields io:, filename: and content_type: and nothing
  # else; Preview#process attaches that as a new blob, and the dimensions come later from analyzing that blob
  # like any other. Returning them here would also mean parsing bytes a tool just made from a hostile
  # document, in this worker, which is what would make these operations in-process ones.
  def test_a_preview_reports_no_dimensions_because_rails_previewers_do_not_either
    Cell.boot do |cell|
      with_output(".png") do |destination|
        result = assert_ok(cell.call("active_storage.preview_pdf", inputs: [ fixture("sample.pdf") ],
                                                                   outputs: [ destination ])).result

        refute result.key?(:width)
        refute result.key?(:height)
      end
    end
  end

  private
    # Mean intensity over the whole image, 0 black to 1 white, from ImageMagick so the claim does not come
    # from the toolchain that produced the bytes.
    def brightness(path)
      value = `magick identify -format '%[fx:mean]' #{path.shellescape} 2>/dev/null`
      skip "ImageMagick is not installed" if value.empty?

      Float(value)
    end
end
