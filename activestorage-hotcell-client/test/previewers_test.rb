# frozen_string_literal: true

require "test_helper"

class PreviewersTest < ActiveStorageHotCellClientTest
  # The whole chain, because the memo behind these predicates is a class-level instance variable and those are
  # not inherited.
  MUPDF = [ ActiveStorage::HotCell::Client::PdfPreviewer, ActiveStorage::Previewer::MuPDFPreviewer ].freeze
  FFMPEG = [ ActiveStorage::HotCell::Client::VideoPreviewer, ActiveStorage::Previewer::VideoPreviewer ].freeze

  # The reason these classes exist as much as the sandboxing is. The built-in accept? shells out with `system`
  # from inside a web request to find out whether the binary is there — and the whole point of a cell is that it
  # is not. Once mutool and ffmpeg leave the application image both answer false, previewable? goes false with
  # them, and previews stop existing. No exception, no alert, nothing in a log.
  def test_accept_does_not_care_whether_the_binary_is_installed
    with_binary_missing MUPDF, :@mutool_exists do
      assert ActiveStorage::HotCell::Client::PdfPreviewer.accept?(Blob.new(fixture("sample.pdf")))
    end

    with_binary_missing FFMPEG, :@ffmpeg_exists do
      assert ActiveStorage::HotCell::Client::VideoPreviewer.accept?(Blob.new(fixture("sample.mp4")))
    end
  end

  # The premise, so the test above cannot pass for the wrong reason: the built-in ones do go false, which is
  # exactly what happens to an application the moment it takes the tools out of its image.
  def test_the_built_in_previewers_do_go_false_without_their_binaries
    with_binary_missing MUPDF, :@mutool_exists do
      refute ActiveStorage::Previewer::MuPDFPreviewer.accept?(Blob.new(fixture("sample.pdf")))
    end

    with_binary_missing FFMPEG, :@ffmpeg_exists do
      refute ActiveStorage::Previewer::VideoPreviewer.accept?(Blob.new(fixture("sample.mp4")))
    end
  end

  # Delegating to the superclass's content-type predicate rather than restating the list is what stops the
  # accepted set drifting away from the one Rails ships.
  def test_the_accepted_content_types_are_the_ones_rails_accepts
    refute ActiveStorage::HotCell::Client::PdfPreviewer.accept?(Blob.new(fixture("colour.png")))
    refute ActiveStorage::HotCell::Client::VideoPreviewer.accept?(Blob.new(fixture("sample.pdf")))
    assert ActiveStorage::HotCell::Client::VideoPreviewer.accept?(Blob.new(fixture("sample.mp4")))
  end

  def test_a_pdf_preview_yields_what_rails_yields
    with_cell do
      preview ActiveStorage::HotCell::Client::PdfPreviewer, "sample.pdf" do |attachable|
        assert_equal "image/png", attachable[:content_type]
        assert_equal "sample.png", attachable[:filename]
        assert_equal "PNG", identify(attachable[:io].path)[:format]
      end
    end
  end

  # Rails' video previewer yields image/jpeg, so this does too. A preview that changed the attached blob's
  # content type would not be a replacement for it.
  def test_a_video_preview_yields_what_rails_yields
    with_cell do
      preview ActiveStorage::HotCell::Client::VideoPreviewer, "sample.mp4" do |attachable|
        assert_equal "image/jpeg", attachable[:content_type]
        assert_equal "sample.jpg", attachable[:filename]
        assert_equal({ width: 64, height: 48, format: "JPEG", frames: 1 }, identify(attachable[:io].path))
      end
    end
  end

  def test_options_are_passed_through_to_the_attachable
    with_cell do
      preview ActiveStorage::HotCell::Client::PdfPreviewer, "sample.pdf", service_name: "somewhere" do |attachable|
        assert_equal "somewhere", attachable[:service_name]
      end
    end
  end

  def test_an_undecodable_document_raises_the_permanent_class
    with_cell do
      assert_raises Unprocessable do
        preview(ActiveStorage::HotCell::Client::PdfPreviewer, "broken.pdf") { flunk "should not have yielded" }
      end
    end
  end

  private
    # The assertions run inside the block, because the io is a Tempfile that is closed and unlinked as soon as
    # the previewer's own block returns — which is the contract, and which a check made afterwards would be
    # reading a deleted file for.
    def preview(previewer, name, **options, &assertions)
      yielded = false
      previewer.new(Blob.new(fixture(name))).preview(**options) do |**attachable|
        yielded = true
        assertions.call attachable
      end

      assert yielded, "the previewer never yielded"
    end
end
