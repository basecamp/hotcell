# frozen_string_literal: true

# Holds a worker for the payload's seconds. Past the cell's deadline it is the input that never finishes;
# under it, several at once are how a queue fills up.
module Examples
  class Sleep < HotCell::Operation
    operation "example.sleep"

    def perform(_inputs, _outputs, seconds:)
      sleep seconds

      { slept: seconds }
    end
  end
end
