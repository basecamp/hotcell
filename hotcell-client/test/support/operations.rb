# frozen_string_literal: true

# The consist this suite points a real cell at. It comes from hotcell-server rather than being written again
# here: five of the operations this file used to define answered to wire names those already claim, so
# `test.uppercase` meant one thing when this suite proved it and another when the server suite did.
require "hot_cell/test_operations"

Fixtures = HotCell::Fixtures

module HotCell
  module Fixtures
    # Its slot home names the cell it ran in, so a test can tell two cells apart. Only this suite boots two.
    class WhereAmI < HotCell::Operation
      operation "test.whereami"

      def perform(_inputs, _outputs, _payload)
        { home: ENV["HOME"] }
      end
    end
  end
end
