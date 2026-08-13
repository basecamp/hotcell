# frozen_string_literal: true

# A worker dying mid-request, both ways it happens: an unclassified exception answers `failed`, and a
# death by signal answers `killed` — the supervisor answers for a worker that cannot. Either way the cell
# must keep serving.
module Examples
  class Crash < HotCell::Operation
    operation "example.crash"

    def perform(_inputs, _outputs, mode: "raise")
      case mode
      when "signal" then Process.kill :KILL, Process.pid
      else raise "crashed on request"
      end
    end
  end
end
