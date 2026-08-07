# frozen_string_literal: true

require "test_helper"

class TransformersVipsTest < ActiveStorageHotCellClientTest
  # The contract Rails relies on: transform yields an open Tempfile positioned at the start, and closes and
  # unlinks it afterwards.
  def test_it_yields_an_open_rewound_tempfile_of_the_converted_image
    with_cell do
      transform({ resize_to_limit: [ 30, 30 ] }, "colour.png") do |output|
        assert_kind_of Tempfile, output
        assert_equal 0, output.pos
        refute_predicate output, :closed?

        assert_equal({ width: 30, height: 20, format: "PNG", frames: 1 }, identify(output.path))
      end
    end
  end

  def test_it_converts_the_format
    with_cell do
      transform({}, "colour.png", format: "webp") { |output| assert_equal "WEBP", identify(output.path)[:format] }
    end
  end

  def test_the_tempfile_is_closed_and_unlinked_afterwards
    with_cell do
      leaked = nil
      transform({ resize_to_limit: [ 10, 10 ] }, "colour.png") { |output| leaked = output }

      assert_predicate leaked, :closed?
    end
  end

  # Rails hands out Tempfiles, which are read-write. The protocol refuses those: an input must be read-only and
  # an output write-only, because an access mode is fixed at open and a cell handed the wrong one can only
  # decline. This passes only because both handles are reopened by path.
  def test_a_rails_tempfile_reaches_the_cell_with_the_access_modes_the_protocol_requires
    with_cell do
      Tempfile.create([ "source", ".png" ], binmode: true) do |readwrite|
        IO.copy_stream fixture("colour.png"), readwrite
        readwrite.flush

        transformer({ resize_to_limit: [ 10, 10 ] }).transform(readwrite, format: "png") do |output|
          assert_operator File.size(output.path), :>, 0
        end
      end
    end
  end

  def test_a_loader_reaches_the_cell_and_keeps_every_frame
    with_cell do
      transform({ loader: { n: -1 } }, "animated.gif", format: "gif") do |output|
        assert_equal 3, identify(output.path)[:frames]
      end
    end
  end

  # The shape HEY has signed into variant URLs, minted on mini_magick. It is refused here for the same reason
  # it raises Vips::Error under Rails on vips: `coalesce` is not a libvips operation. Making these URLs work is
  # an ImageMagick-compatible transformer, which is a planned addition — until then an application that moves
  # from mini_magick to vips rewrites them at its own boundary, the way BC4 does.
  def test_the_imagemagick_shape_is_refused_rather_than_silently_reinterpreted
    with_cell do
      error = assert_raises Unprocessable do
        transform({ loader: { page: nil }, coalesce: true }, "animated.gif", format: "gif") { flunk "no" }
      end

      assert_match "coalesce", error.message
    end
  end

  def test_an_undecodable_image_raises_the_applications_permanent_class
    with_cell do
      assert_raises Unprocessable do
        transform({}, "broken.png") { flunk "should not have yielded" }
      end
    end
  end

  # A caller bug, not a verdict on the document. It has to be told apart from an undecodable image, because one
  # gets a placeholder and the other should reach an exception reporter.
  def test_a_transformation_outside_the_cells_allowlist_raises_the_permanent_class
    with_cell do
      error = assert_raises Unprocessable do
        transform({ system: "id" }, "colour.png") { flunk "should not have yielded" }
      end

      assert_match "invalid", error.message
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
      ActiveStorage::HotCell::Client::Transformers::Vips.new transformations
    end

    def transform(transformations, name, format: "png", &block)
      File.open(fixture(name), "rb") do |file|
        transformer(transformations).transform(file, format: format, &block)
      end
    end
end
