# frozen_string_literal: true

require "digest"

# Fixture operations, so the whole surface can be exercised with no converter installed and no container
# running. haystack#8538 does the same thing with a scripted stand-in for soffice, which lets it test the
# whole surface in milliseconds.
module Fixtures
  class Uppercase < HotCell::Operation
    operation "test.uppercase"

    def perform(inputs, outputs, _payload)
      source, = inputs
      destination, = outputs
      File.binwrite destination.path, File.binread(source.path).upcase

      { bytes: File.size(destination.path) }
    end
  end

  # Two inputs, one output, so the request shape with several inputs is covered.
  class Concatenate < HotCell::Operation
    operation "test.concatenate"

    def perform(inputs, outputs, payload)
      destination, = outputs
      File.binwrite destination.path, inputs.map { |input| File.binread(input.path) }.join(payload[:separator].to_s)

      { inputs: inputs.size }
    end
  end

  # Analysis: metadata out and no bytes, which is the shape with no outputs at all.
  class Measure < HotCell::Operation
    operation "test.measure"

    def perform(inputs, _outputs, payload)
      source, = inputs

      { bytes: File.size(source.path), digest: Digest::SHA256.file(source.path).hexdigest[0, 8],
        asked_for: payload[:asked_for] }
    end
  end

  # No inputs and no outputs, like rendering an initials avatar from nothing but a payload.
  class Echo < HotCell::Operation
    operation "test.echo"

    def perform(_inputs, _outputs, payload)
      { echoed: payload }
    end
  end

  class WhoAmI < HotCell::Operation
    operation "test.whoami"

    def perform(_inputs, _outputs, _payload)
      { pid: Process.pid, home: ENV["HOME"], scratch: Dir.exist?(scratch_path) }
    end

    private
      def scratch_path
        File.join ENV["HOME"].to_s, "..", "scratch"
      end
  end

  # An operation that reads what a caller gave it without a copy onto scratch, which is what an operation
  # reading only a container header wants rather than a multi-gigabyte copy.
  class Reverse < HotCell::Operation
    operation "test.reverse"
    stage :descriptors

    def perform(inputs, outputs, _payload)
      outputs.first.to_io.write inputs.first.to_io.read.reverse

      { staged: !inputs.first.staged? }
    end
  end

  class Broken < HotCell::Operation
    operation "test.broken"

    def perform(_inputs, _outputs, _payload)
      raise "the operation itself is broken"
    end
  end

  class Undecodable < HotCell::Operation
    operation "test.undecodable"

    def perform(_inputs, _outputs, _payload)
      raise HotCell::UnreadableInput, "not an image at all"
    end
  end

  # A library exception an operation declares as meaning "the input could not be decoded", the way the
  # Active Storage operations will declare Vips::Error.
  class LibraryError < StandardError; end

  class DeclaredUnreadable < HotCell::Operation
    operation "test.declared_unreadable"
    unreadable LibraryError

    def perform(_inputs, _outputs, _payload)
      raise LibraryError, "the library says no"
    end
  end

  class Hungry < HotCell::Operation
    operation "test.hungry"

    def perform(_inputs, _outputs, _payload)
      raise HotCell::MemoryExhausted, "out of memory -- size == 732MB"
    end
  end

  class BadResult < HotCell::Operation
    operation "test.bad_result"

    def perform(_inputs, _outputs, _payload)
      "a String is not a result"
    end
  end

  class UnserializableResult < HotCell::Operation
    operation "test.unserializable_result"

    def perform(_inputs, _outputs, _payload)
      { format: :png }
    end
  end

  # Returns without writing anything, which is how a full tmpfs arrives too.
  class Silent < HotCell::Operation
    operation "test.silent"

    def perform(_inputs, _outputs, _payload)
      {}
    end
  end

  class Overflowing < HotCell::Operation
    operation "test.overflowing"

    def perform(_inputs, outputs, payload)
      File.open(outputs.first.path, "wb") do |file|
        payload.fetch(:megabytes).times { file.write "x" * (1024 * 1024) }
        file.flush
      end

      {}
    end
  end

  # Pins the worker where Ruby cannot interrupt it.
  #
  # A deadline test built on sleep passes against a self-enforcing implementation that could never work in
  # production, because Timeout raises at an interrupt checkpoint and a thread in a C extension does not
  # reach one until it returns. libvips is the real case; Integer#** is the one in the standard library.
  # Measured: 3 ** 20_000_000 runs for 2.3 seconds straight through a 0.05 second Timeout.
  class Uninterruptible < HotCell::Operation
    operation "test.uninterruptible"
    EXPONENT = 20_000_000

    def self.blocks_through_a_timeout?
      require "timeout"
      Timeout.timeout(0.05) { 3**5_000_000 }
      true
    rescue Timeout::Error
      false
    end

    def perform(_inputs, _outputs, _payload)
      { digits: (3**EXPONENT).bit_length }
    end
  end

  # Declares less than the cell allows, so the supervisor has to learn the narrower number from the worker
  # rather than from the request it never reads.
  class Impatient < HotCell::Operation
    operation "test.impatient"
    limits deadline: 1

    def perform(_inputs, _outputs, _payload)
      { digits: (3**Uninterruptible::EXPONENT).bit_length }
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
