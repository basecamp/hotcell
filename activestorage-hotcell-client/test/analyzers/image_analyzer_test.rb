# frozen_string_literal: true

require "test_helper"

class ImageAnalyzerVipsTest < ActiveStorageHotCellClientTest
  def test_it_accepts_images_whatever_the_variant_processor_is
    assert ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips.accept?(Blob.new(fixture("colour.png")))
    refute ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips.accept?(Blob.new(fixture("sample.pdf")))
  end

  def test_it_returns_the_dimensions_the_built_in_analyzer_returns
    with_cell do
      assert_equal({ width: 60, height: 40 }, analyze("colour.png"))
    end
  end

  def test_it_reports_the_dimensions_exif_asks_for
    with_cell do
      assert_equal({ width: 40, height: 60 }, analyze("rotated.jpg"))
    end
  end

  # The built-in vips analyzer rescues every Vips::Error and returns an empty hash, which Rails merges with
  # `analyzed: true` — so an undecodable image is recorded as successfully analyzed, forever, and nothing ever
  # re-enqueues AnalyzeJob. That is the right answer for a permanent verdict, so it is copied deliberately.
  def test_a_permanently_undecodable_image_is_marked_analyzed_the_way_rails_marks_it
    with_cell do
      assert_empty analyze("broken.png")
    end
  end

  # And this is the half that must not be copied. A transient failure is not rescued at all, which leaves the
  # blob analyzed: false and eligible to be tried again. Recording a cell restart as "this image is
  # unanalyzable, forever" is the failure this whole gem exists to avoid.
  def test_a_transient_failure_raises_so_the_blob_stays_unanalyzed
    with_canned_response failed("capacity")

    assert_raises TemporarilyUnavailable do
      ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips.new(Blob.new(fixture("colour.png"))).metadata
    end
  end

  def test_a_cell_that_is_not_there_raises_rather_than_marking_the_blob_analyzed
    with_canned_response failed("unavailable")

    assert_raises TemporarilyUnavailable do
      ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips.new(Blob.new(fixture("colour.png"))).metadata
    end
  end

  private
    def analyze(name)
      ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips.new(Blob.new(fixture(name))).metadata
    end
end
