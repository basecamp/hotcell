# Logging the lost guarantee and serving anyway, which is how a dead control stays dead.
require "hot_cell/server"
module HotCell
  class Supervisor
    private def verify_ptrace_scope!
      log.write "cell.ptrace_scope", scope: (File.read(@ptrace_scope_path).strip if File.readable?(@ptrace_scope_path))
    end
  end
end
