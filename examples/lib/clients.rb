# frozen_string_literal: true

require "hot_cell/client"

# The application side of the example operations: one thin class per operation, the way an application
# writes them. These share names with the operation classes in ../operations on purpose — a client loads
# here, an operation loads in the cell's process, and the two never meet.
module Examples
  CELL = "example"

  class Echo < ::HotCell::Client
    hotcell CELL
    operation "example.echo"
  end

  class Reopen < ::HotCell::Client
    hotcell CELL
    operation "example.reopen"
  end

  class Tamper < ::HotCell::Client
    hotcell CELL
    operation "example.tamper"
  end

  class Sleep < ::HotCell::Client
    hotcell CELL
    operation "example.sleep"
  end

  class Greedy < ::HotCell::Client
    hotcell CELL
    operation "example.greedy"
  end

  class Overflow < ::HotCell::Client
    hotcell CELL
    operation "example.overflow"
  end

  class Crash < ::HotCell::Client
    hotcell CELL
    operation "example.crash"
  end

  class Spawn < ::HotCell::Client
    hotcell CELL
    operation "example.spawn"
  end

  class Probe < ::HotCell::Client
    hotcell CELL
    operation "example.probe"
  end

  class Isolation < ::HotCell::Client
    hotcell CELL
    operation "example.isolation"
  end
end
