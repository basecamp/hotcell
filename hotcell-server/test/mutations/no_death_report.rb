require "hot_cell/server"
module HotCell; class Supervisor; private def answer_for(child, status) = child.connection&.close; end; end
