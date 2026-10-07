# frozen_string_literal: true

require "test_helper"
require "open3"

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

  # Rails names a web image's variant format after its upload's extension, so a JPEG uploaded as `photo.jfif`
  # asks for format `jfif` (#84).
  %w[ jfif JFIF jif jfi ].each do |format|
    define_method :"test_a_jpeg_uploaded_as_#{format}_comes_back_as_a_jpeg" do
      with_cell do
        with_active_storage_setting :web_image_content_types, %w[ image/png image/jpeg image/gif ] do
          transform({ resize_to_limit: [ 20, 20 ] }, "colour.jpg", format: format) do |output|
            assert_equal "JPEG", identify(output.path)[:format]
            assert_operator identify(output.path)[:width], :<=, 20
          end
        end
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

  # image_processing 2.x no longer depends on mini_magick, so an application on vips may not have it. Only a
  # fresh process can show what requiring the gem loads, and a stand-in first on the load path makes
  # `require "mini_magick"` fail the way it does when the gem is not installed. Rails is loaded first, as
  # Bundler.require does in an application, so the railtie is loaded too.
  def test_the_gem_loads_without_mini_magick
    output, status = ruby_without_mini_magick <<~RUBY
      require "rails"
      require "activestorage-hotcell-client"
    RUBY

    assert_predicate status, :success?, output
  end

  def test_naming_the_transformer_without_mini_magick_raises_load_error
    output, status = ruby_without_mini_magick <<~RUBY
      require "active_storage/hot_cell/client"
      puts "loaded"
      ActiveStorage::HotCell::Client::Transformers::Image::Magick
    RUBY

    refute_predicate status, :success?
    assert_match(/^loaded$/, output)
    assert_match "requires the mini_magick gem", output
  end

  private
    def ruby_without_mini_magick(script)
      Dir.mktmpdir "hotcell-no-mini-magick" do |dir|
        File.write File.join(dir, "mini_magick.rb"), 'raise LoadError, "cannot load such file -- mini_magick"'

        Open3.capture2e RbConfig.ruby, "-I", dir, "-I", File.expand_path("../../lib", __dir__), "-e", script
      end
    end

    def transformer(transformations)
      ActiveStorage::HotCell::Client::Transformers::Image::Magick.new transformations
    end

    def transform(transformations, name, format: "png", &block)
      File.open(fixture(name), "rb") do |file|
        transformer(transformations).transform(file, format: format, &block)
      end
    end
end
