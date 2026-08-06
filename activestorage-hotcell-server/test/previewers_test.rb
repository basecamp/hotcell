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

        assert_predicate failure, :terminal?
        assert_match "mutool", failure.message
      end
    end
  end

  def test_a_video_preview_comes_back_as_a_png
    Cell.boot do |cell|
      with_output(".png") do |destination|
        response = cell.call "active_storage.preview_video",
                             inputs: [ fixture("sample.mp4") ], outputs: [ destination ]

        assert_ok response
        assert_equal({ width: 64, height: 48, format: "PNG", frames: 1 }, identify(destination))
      end
    end
  end

  def test_a_video_preview_can_be_taken_from_further_in
    Cell.boot do |cell|
      with_output(".png") do |destination|
        assert_ok cell.call("active_storage.preview_video", inputs: [ fixture("sample.mp4") ],
                                                            outputs: [ destination ], payload: { seek: 0.5 })

        assert_equal "PNG", identify(destination)[:format]
      end
    end
  end

  # video_preview_arguments is a shell string an application can set, and Rails splits it with Shellwords. A cell
  # exists so that nobody but the operation chooses what a converter runs, so the payload carries one number.
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

        assert_predicate failure, :terminal?
      end
    end
  end

  # This is what Rails does, not a concession. A previewer yields io:, filename: and content_type: and nothing
  # else; Preview#process attaches that as a new blob, and the dimensions come later from analyzing that blob
  # like any other. Returning them here would also mean parsing bytes a converter just made from a hostile
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
end
