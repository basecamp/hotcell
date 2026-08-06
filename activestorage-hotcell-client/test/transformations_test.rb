# frozen_string_literal: true

require "test_helper"

# A variant's address is a signed serialization of the whole transformations hash, carried inside the URL and
# never expiring. So every shape any caller has ever minted has to keep decoding, permanently, and the mapping
# happens here rather than by asking call sites to pass something else.
class TransformationsTest < ActiveStorageHotCellClientTest
  def test_an_ordinary_resize_passes_through
    assert_equal({ format: "png", operations: { resize_to_limit: [ 100, 100 ] } },
                 map({ resize_to_limit: [ 100, 100 ] }))
  end

  def test_the_format_argument_wins_over_the_one_merged_into_the_hash
    # default_to merges format: in before the URL key is signed, so it arrives twice and the argument is the one
    # Rails actually asked for.
    assert_equal "webp", map({ resize_to_limit: [ 100, 100 ], format: :png }, format: "webp")[:format]
  end

  def test_string_keys_map_the_same_as_symbols
    assert_equal map({ resize_to_limit: [ 100, 100 ] }),
                 map({ "resize_to_limit" => [ 100, 100 ] })
  end

  # HEY's three live URL-minting call sites pass this, on ImageMagick, to keep animated GIFs animated. It has to
  # keep meaning that forever.
  def test_the_imagemagick_way_of_asking_for_every_frame
    mapped = map({ loader: { page: nil }, coalesce: true, resize_to_limit: [ 100, 100 ] })

    assert mapped[:animated]
    assert_equal({ resize_to_limit: [ 100, 100 ] }, mapped[:operations])
  end

  def test_the_vips_way_of_asking_for_every_frame
    assert map({ loader: { n: -1 } })[:animated]
  end

  def test_coalesce_alone_is_the_same_request
    assert map({ coalesce: true })[:animated]
  end

  def test_a_loader_that_asks_for_one_page_is_not_asking_for_every_frame
    refute map({ loader: { page: 0 } })[:animated]
  end

  def test_nothing_said_about_frames_means_the_first_one
    refute map({ resize_to_limit: [ 100, 100 ] }).key?(:animated)
  end

  # Saver options belong to the operation. These two arrive as intent because they are already signed into URLs.
  def test_quality_and_strip_survive_from_either_spelling
    assert_equal 40, map({ quality: 40 })[:quality]
    assert_equal 40, map({ saver: { quality: 40 } })[:quality]
    assert_equal 40, map({ saver: { Q: 40 } })[:quality]
    assert map({ strip: true })[:strip]
    assert map({ saver: { strip: true } })[:strip]
  end

  # This is what haystack passes today, on mini_magick, where quality and strip are ImageMagick options. On the
  # vips path they raise as transformations, so mapping them onto saver intent is what keeps those URLs working.
  def test_the_shape_haystack_mints_today
    mapped = map({ resize_to_fill: [ 300, 300 ], quality: 40, strip: true })

    assert_equal({ resize_to_fill: [ 300, 300 ] }, mapped[:operations])
    assert_equal 40, mapped[:quality]
    assert mapped[:strip]
  end

  # Library keywords are the operation's to choose. A cell exists so that a caller cannot hand a media library
  # its own options, and passing these through would put them back.
  def test_no_library_keyword_reaches_the_operation
    mapped = map({ loader: { n: -1 }, saver: { quality: 40, strip: true }, coalesce: true,
                 quality: 30, strip: true, format: :gif, resize_to_fit: [ 10, 10 ] })

    assert_equal [ :resize_to_fit ], mapped[:operations].keys
  end

  # Anything unrecognised goes to the cell, which has the allowlist and will refuse it as a caller bug. Guessing
  # here would mean two allowlists disagreeing.
  def test_an_unknown_transformation_is_left_for_the_cell_to_judge
    assert_equal({ something_new: 1 }, map({ something_new: 1 })[:operations])
  end

  private
    def map(transformations, format: "png")
      ActiveStorage::HotCell::Client::Transformations.call transformations, format: format
    end
end
