# frozen_string_literal: true

require "test_helper"

# libvips carries loaders that have never been fuzzed, and `Vips.block_untrusted true` turns them off. Rails
# does this in `active_storage/vips` and tests it by feeling for the formats that disappear — PSD, ICO, BMP, SVG
# all stop decoding. This does the same from inside a real cell, which additionally proves the call happened in
# the worker rather than only in the file that defines the operation.
#
# The control is one line in `before_worker_boot`, and nothing else in this suite would notice its removal: every
# other fixture decodes through a fuzzed loader either way. That is the definition of a control worth testing.
class BlockedLoadersTest < ActiveStorageHotCellTest
  # Each of these is a real image that ImageMagick reads happily, and each is read by a loader libvips refuses
  # to run on untrusted input.
  BLOCKED = %w[ icon.svg colour.bmp colour.ico ].freeze

  def test_an_unfuzzed_loader_is_refused_rather_than_run
    Cell.boot do |cell|
      BLOCKED.each do |name|
        failure = assert_failed "unreadable", cell.call("active_storage.analyze_image", inputs: [ fixture(name) ])

        assert_equal "Vips::Error", failure.error_class, "#{name} should be refused by libvips"
      end
    end
  end

  def test_a_transform_of_a_blocked_format_is_refused_too
    Cell.boot do |cell|
      with_output(".png") do |destination|
        assert_failed "unreadable", cell.call("active_storage.transform_image",
                                              inputs: [ fixture("icon.svg") ], outputs: [ destination ],
                                              payload: { format: "png" })
      end
    end
  end

  # The premise, so that the assertions above cannot pass for the wrong reason. These files are images: an
  # independent tool reads every one of them.
  def test_the_blocked_fixtures_are_real_images
    BLOCKED.each do |name|
      identified = identify(fixture(name))

      assert_operator identified[:width], :>, 0, "#{name} is not a readable image"
    end
  end

  # And the formats that stay available, so the test above is measuring the loader rather than the cell being
  # broken for everything.
  def test_the_fuzzed_loaders_still_work
    Cell.boot do |cell|
      %w[ colour.png colour.jpg animated.gif ].each do |name|
        assert_ok cell.call("active_storage.analyze_image", inputs: [ fixture(name) ])
      end
    end
  end
end
