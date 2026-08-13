# frozen_string_literal: true

# What a worker can see of its container, for the checks only a containerized run can make: the network
# interfaces, whether the root filesystem takes a write, whether scratch is mounted noexec, and what an
# exec'd tool sees of the environment. Each answers nil where the platform cannot say (macOS has no /sys
# and no /proc), so the same file loads in a native development cell.
module Examples
  class Isolation < HotCell::Operation
    operation "example.isolation"

    def perform(_inputs, _outputs)
      tool = run_tool("env")

      { interfaces: interfaces,
        writable_root: File.writable?("/"),
        scratch_noexec: scratch_noexec?,
        tool_env: tool.ok? ? tool.out.lines.map { |line| line.split("=", 2).first }.sort : nil }
    end

    private
      def interfaces
        Dir.exist?("/sys/class/net") ? Dir.children("/sys/class/net").sort : nil
      end

      def scratch_noexec?
        return nil unless File.exist?("/proc/self/mounts")

        File.read("/proc/self/mounts").lines.grep(%r{ /tmp .*noexec}).any?
      end
  end
end
