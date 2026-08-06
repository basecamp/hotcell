# frozen_string_literal: true

# Enough of a cell's consist to exercise the client against a real one. The cell carries whatever this
# process has defined, because a worker inherits the registry through the fork.
module Fixtures
  class Uppercase < HotCell::Operation
    operation "test.uppercase"

    def perform(inputs, outputs, _payload)
      File.binwrite outputs.first.path, File.binread(inputs.first.path).upcase

      { bytes: File.size(outputs.first.path) }
    end
  end

  class Echo < HotCell::Operation
    operation "test.echo"

    def perform(_inputs, _outputs, payload)
      { echoed: payload }
    end
  end

  class Undecodable < HotCell::Operation
    operation "test.undecodable"

    def perform(_inputs, _outputs, _payload)
      raise HotCell::UnreadableInput, "not an image at all"
    end
  end

  # Reports success and writes nothing, which is also how a full tmpfs arrives.
  class Silent < HotCell::Operation
    operation "test.silent"

    def perform(_inputs, _outputs, _payload)
      {}
    end
  end

  # Its slot home names the cell it ran in, so a test can tell two cells apart.
  class WhereAmI < HotCell::Operation
    operation "test.whereami"

    def perform(_inputs, _outputs, _payload)
      { home: ENV["HOME"] }
    end
  end

  class Blocking < HotCell::Operation
    operation "test.blocking"

    def perform(_inputs, _outputs, payload)
      sleep payload.fetch(:seconds)

      { slept: payload[:seconds] }
    end
  end
end
