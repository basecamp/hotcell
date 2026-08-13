# frozen_string_literal: true

# The happy path and the fast baseline. The message arrives through the caller's own input descriptor and
# leaves through the caller's own output descriptor, with no copy onto scratch — so one round-trip proves
# the SCM_RIGHTS descriptor passing end to end.
module Examples
  class Echo < HotCell::Operation
    operation "example.echo"

    def perform(inputs, outputs)
      bytes = outputs.first.to_io.write(inputs.first.to_io.read)

      { bytes: bytes, staged: inputs.first.staged? }
    end
  end
end
