# frozen_string_literal: true

require "test_helper"

class TransformersImageMagickTest < ActiveStorageHotCellClientTest
  def test_it_yields_an_open_rewound_tempfile_of_the_converted_image
    with_cell do
      transform({ resize_to_limit: [ 30, 30 ] }, "colour.png") do |output|
        assert_kind_of Tempfile, output
        assert_equal 0, output.pos
        refute_predicate output, :closed?

        assert_operator identify(output.path)[:width], :<=, 30
      end
    end
  end

  # The shape the vips path refuses: coalesce is a real ImageMagick operation, and this is the transformer
  # that makes an application's mini_magick-minted variant URLs work.
  def test_an_imagemagick_shape_the_vips_path_refuses_is_run
    with_cell do
      transform({ coalesce: true, resize_to_limit: [ 20, 20 ] }, "animated.gif", format: "gif") do |output|
        assert_equal "GIF", identify(output.path)[:format]
      end
    end
  end

  # Rails' ImageMagick allowlist runs here, in the application, before anything reaches the cell: a method
  # outside supported_image_processing_methods raises the same error Rails raises, and no request is sent.
  def test_a_transformation_outside_rails_allowlist_is_refused_before_the_cell
    error = assert_raises ActiveStorage::Transformers::ImageProcessingTransformer::UnsupportedImageProcessingMethod do
      transformer({ system: "id" }).transform(File.open(fixture("colour.png")), format: "png") { flunk "no" }
    end

    assert_match "system", error.message
  end

  def test_an_undecodable_image_raises_the_permanent_class
    with_cell do
      assert_raises Unprocessable do
        transform({}, "broken.png") { flunk "should not have yielded" }
      end
    end
  end

  def test_a_cell_that_is_not_there_raises_the_transient_class
    HotCell.root = Dir.mktmpdir "hotcell-absent"
    HotCell.register ActiveStorage::HotCell::Client::CELL, permanent: Unprocessable, transient: TemporarilyUnavailable

    assert_raises TemporarilyUnavailable do
      transform({}, "colour.png") { flunk "should not have yielded" }
    end
  end

  private
    def transformer(transformations)
      ActiveStorage::HotCell::Client::Transformers::ImageMagick.new transformations
    end

    def transform(transformations, name, format: "png", &block)
      File.open(fixture(name), "rb") do |file|
        transformer(transformations).transform(file, format: format, &block)
      end
    end
end
