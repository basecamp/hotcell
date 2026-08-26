# frozen_string_literal: true

# The two round trips an application runs against its own cell for a health check. Shipped in the
# gem because every deployment was copying them from examples/, and copies drift.
#
# A cell serves them only if it requires this file.
module HotCell
  module Health
    # The message goes in through the caller's input descriptor and out through the caller's output
    # descriptor, with no copy onto scratch, so one round trip proves descriptor passing end to end.
    class Echo < HotCell::Operation
      operation "health.echo"

      def perform(inputs, outputs)
        bytes = outputs.first.to_io.write(inputs.first.to_io.read)

        { bytes: bytes, staged: inputs.first.staged? }
      end
    end

    # /dev/fd/N is a fresh open, checked against this process's uid and the file's mode, so this
    # succeeds only when the cell can open the caller's files by name — which echo never checks.
    # It reads the input and writes the output, because a tool may need either permission.
    class Reopen < HotCell::Operation
      operation "health.reopen"

      def perform(inputs, outputs)
        source, = inputs
        destination, = outputs

        bytes = File.open(source.fd_path, "rb") do |input|
          File.open(destination.fd_path, "wb") { |output| output.write(input.read) }
        end

        { bytes: bytes, staged: source.staged? || destination.staged? }
      end
    end
  end
end
