# frozen_string_literal: true

# What a worker can see of its container, for the checks only a containerized run can make: the network
# interfaces, whether the root filesystem takes a write, whether scratch is mounted noexec, the container
# security flags the kernel exposes in /proc/self/status — the bounding capability set (cap-drop), the
# no-new-privileges bit, and the uid the cell runs as — and what an exec'd tool sees of the environment.
# Each answers nil where the platform cannot say (macOS has no /sys and no /proc), so the same file loads
# in a native development cell; the battery reads that nil as a failed check rather than a pass, so a cell
# that cannot report a flag never passes for silence.
module Examples
  class Isolation < HotCell::Operation
    operation "example.isolation"

    def perform(_inputs, _outputs)
      tool = run_tool("env")

      { interfaces: interfaces,
        writable_root: File.writable?("/"),
        root_readonly: root_readonly,
        scratch_noexec: scratch_noexec?,
        cap_bound: cap_bound,
        no_new_privs: no_new_privs,
        uid: Process.uid,
        tool_env: tool.ok? ? tool.out.lines.map { |line| line.split("=", 2).first }.sort : nil }
    end

    private
      def interfaces
        Dir.exist?("/sys/class/net") ? Dir.children("/sys/class/net").sort : nil
      end

      # Whether the root filesystem is mounted read-only, read from its mount options rather than from
      # File.writable?("/"): the cell runs as a non-root user, so `/` is unwritable to it whether or not
      # the container is read-only, and only the mount flag distinguishes the two.
      def root_readonly
        options = mount_options("/")
        options && options.include?("ro")
      end

      def scratch_noexec?
        options = mount_options("/tmp")
        options && options.include?("noexec")
      end

      def mount_options(mountpoint)
        return nil unless File.exist?("/proc/self/mounts")

        line = File.foreach("/proc/self/mounts").find { |mount| mount.split(" ")[1] == mountpoint }
        line && line.split(" ")[3].split(",")
      end

      # The bounding capability set as an integer: 0 once the accessory's cap-drop ALL has taken it away,
      # and a non-zero mask (Docker's default is 0x00000000a80425fb) when it has not.
      def cap_bound
        field = status_field("CapBnd")
        field && Integer(field, 16)
      end

      # Whether the no-new-privileges bit is set, which is what stops a setuid binary regaining a dropped
      # capability. The kernel writes it as 1 or 0.
      def no_new_privs
        field = status_field("NoNewPrivs")
        field && field == "1"
      end

      def status_field(name)
        return nil unless File.exist?("/proc/self/status")

        line = File.foreach("/proc/self/status").find { |candidate| candidate.start_with?("#{name}:") }
        line&.split(":", 2)&.last&.strip
      end
  end
end
