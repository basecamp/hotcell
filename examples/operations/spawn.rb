# frozen_string_literal: true

# Starts a grandchild that would outlive the worker and does not wait for it — the way a crashed worker
# leaves a tool behind. The supervisor's group sweep at reap is what must kill it. Reports the pid so
# `example.probe` can watch for it.
module Examples
  class Spawn < HotCell::Operation
    operation "example.spawn"

    def perform(_inputs, _outputs)
      { pid: Process.spawn("sleep", "300") }
    end
  end
end
