# frozen_string_literal: true

require "socket"
require "time"

module HotCell
  class Diagnosis
    attr_reader :cells

    def initialize(cells, work:)
      @at = Time.now.utc.iso8601(3)
      @host = Socket.gethostname
      @cells = cells.to_h { |cell| [ cell.name, cell.diagnose(work: work) ] }
    end

    # `cells.any?`, so an application that never registered a cell does not answer OK.
    def healthy?
      cells.any? && cells.each_value.all? { |checks| checks.each_value.all? { |check| check[:ok] } }
    end

    # `host` because sockets are host-local, and a poll through a load balancer lands wherever it lands.
    def as_json(*)
      { at: @at, host: @host, healthy: healthy?, cells: cells }
    end
  end
end
