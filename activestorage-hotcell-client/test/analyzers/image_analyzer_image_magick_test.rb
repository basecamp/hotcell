# frozen_string_literal: true

require "test_helper"

class ImageAnalyzerImageMagickTest < ActiveStorageHotCellClientTest
  Analyzer = ActiveStorage::HotCell::Client::Analyzers::Image::Magick

  def test_it_accepts_images
    assert Analyzer.accept?(Blob.new(fixture("colour.png")))
    refute Analyzer.accept?(Blob.new(fixture("sample.pdf")))
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

  def test_a_permanently_undecodable_image_is_marked_analyzed_the_way_rails_marks_it
    with_cell do
      assert_empty analyze("broken.png")
    end
  end

  def test_a_transient_failure_raises_so_the_blob_stays_unanalyzed
    with_canned_response failed("capacity")

    assert_raises TemporarilyUnavailable do
      Analyzer.new(Blob.new(fixture("colour.png"))).metadata
    end
  end

  private
    def analyze(name)
      Analyzer.new(Blob.new(fixture(name))).metadata
    end
end
