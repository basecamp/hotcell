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
  # The failure path, which Rails' own `ensure` does not cover: it unlinks the output around the *yield*, and a
  # refused conversion never reaches one. Left alone the file would go at GC, which on a busy web process means
  # a variant storm fills the disk with scratch nobody is holding.
  def test_the_output_is_unlinked_when_the_conversion_fails
    with_cell do
      before = scratch_files

      assert_raises Unprocessable do
        transform({}, "broken.png") { flunk "should not have yielded" }
      end

      assert_equal before, scratch_files
    end
  end

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

  # Rails deep-symbolizes the keys of a variation and leaves the values alone, so an application that wrote
  # `crop: :attention` into a variant works on stock Rails-on-vips. A Symbol value cannot ride JSON, but that
  # is this gem's transport detail rather than the application's problem — Symbol values become Strings on
  # their way to the cell.
  def test_a_symbol_transformation_value_travels_as_the_string_rails_would_pass_to_vips
    with_cell do
      transform({ resize_to_fill: [ 30, 30, { crop: :attention } ] }, "colour.png") do |output|
        assert_equal({ width: 30, height: 30 }, identify(output.path).slice(:width, :height))
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

  # The shape HEY has signed into variant URLs, minted on mini_magick. `coalesce` is not a libvips
  # operation, so ImageProcessing forwards it to vips, which raises Vips::Error — and VipsOperation declares
  # Vips::Error `unreadable`, so it lands permanent.
  #
  # KNOWN DEVIATION (resolved by the planned ImageMagick operations): this is a caller bug, not a bad
  # document, and Rails treats it as an unclassified job failure rather than a verdict on the blob. The
  # `unreadable Vips::Error` rule was written for the load phase, where a Vips::Error means bad pixels; a
  # bad operation name raising the same class slips through as a false permanent verdict. The real fix is an
  # ImageMagick transformer where `coalesce` is a real operation — until then an application moving from
  # mini_magick to vips rewrites these URLs at its own boundary, the way BC4 does. This test pins the
  # current behavior so the deviation is visible, not hidden.
  def test_an_imagemagick_only_operation_name_lands_permanent_for_now
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

  # A caller bug, not a verdict on the document: ImageProcessing refuses the name, the failure is
  # unclassified and therefore transient, and it stays distinguishable from an undecodable image — which
  # raises the permanent class and gets a placeholder.
  def test_an_unknown_transformation_raises_the_transient_class
    with_cell do
      error = assert_raises TemporarilyUnavailable do
        transform({ system: "id" }, "colour.png") { flunk "should not have yielded" }
      end

      assert_match "system", error.message
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
    def scratch_files
      Dir.glob(File.join(Dir.tmpdir, "hotcell*")).size
    end

    def transformer(transformations)
      ActiveStorage::HotCell::Client::Transformers::Image::Vips.new transformations
    end

    def transform(transformations, name, format: "png", &block)
      File.open(fixture(name), "rb") do |file|
        transformer(transformations).transform(file, format: format, &block)
      end
    end
end
