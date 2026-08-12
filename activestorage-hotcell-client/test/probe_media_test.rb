# frozen_string_literal: true

require "test_helper"

# ProbeMedia has no analyzer wrapping it yet, so this round trip is the one thing pinning its wire name
# and result shape to the operation the cell registers under the same name.
class ProbeMediaTest < ActiveStorageHotCellClientTest
  def test_probing_crosses_the_boundary_and_returns_the_shape
    with_cell do
      File.open(fixture("sample.mp4"), "rb") do |readable|
        result = ActiveStorage::HotCell::Client::ProbeMedia.perform_in_hotcell [ readable ], []

        assert_equal 64, result[:width]
        assert_equal 48, result[:height]
        assert_equal "h264", result[:video_codec]
        assert_in_delta 1.0, result[:duration], 0.2
      end
    end
  end
end
