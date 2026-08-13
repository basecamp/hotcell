# frozen_string_literal: true

# Whether a pid is still alive, asked from inside the cell — the only place that shares a pid namespace
# with a containerized worker's leftovers. Signal 0 checks without touching.
module Examples
  class Probe < HotCell::Operation
    operation "example.probe"

    def perform(_inputs, _outputs, pid:)
      Process.kill 0, Integer(pid)

      { alive: true }
    rescue Errno::ESRCH
      { alive: false }
    end
  end
end
