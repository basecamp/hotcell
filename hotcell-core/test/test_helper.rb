# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "socket"

require "hot_cell/core"
require "hot_cell/test_support"

class HotCellTest < Minitest::Test
  include HotCell::TestSupport
end
