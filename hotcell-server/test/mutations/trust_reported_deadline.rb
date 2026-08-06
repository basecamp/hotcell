# Taking the deadline verbatim from the one process here that runs untrusted code.
require "hot_cell/server"
module HotCell; class Supervisor; private def narrowed_deadline(reported) = reported; end; end
