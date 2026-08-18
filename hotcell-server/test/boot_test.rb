# frozen_string_literal: true

require "test_helper"

# A cell that is configured wrongly has to say so at boot rather than at the first request.
#
# Only one of these refuses to start, and it is the one where nothing else could ever notice: kernel.yama's
# ptrace_scope is a host sysctl, invisible to the image, and at 0 it silently voids the only thing stopping one
# worker from reading another request's memory.
class BootTest < RegistryIsolatedTest
  # Request memory is protected by kernel.yama.ptrace_scope and by nothing else. No container flag can set
  # it, so a cell that finds it off has lost the guarantee, and a warning in a log is how a dead control
  # stays dead.
  def test_a_host_where_a_worker_could_read_a_siblings_memory_refuses_to_boot
    with_file "0" do |path|
      error = assert_raises(RuntimeError) { HotCell::TestCell.boot(supervisor: { ptrace_scope_path: path }) { nil } }

      assert_match "kernel.yama.ptrace_scope is 0", error.message
      assert_match "No container flag can set it", error.message
    end
  end

  def test_a_protected_host_boots
    with_file "1" do |path|
      TestCell.boot(supervisor: { ptrace_scope_path: path }) do |cell|
        assert_ok cell.call("test.echo")
      end
    end
  end

  # Development on a platform with no /proc, or a kernel built without Yama. That is not a deployment with a
  # broken precondition, so it says what it could not check and carries on.
  def test_a_host_where_it_cannot_be_checked_boots_and_says_so
    TestCell.boot(supervisor: { ptrace_scope_path: "/nonexistent/ptrace_scope" }) do |cell|
      assert_ok cell.call("test.echo")
      cell.stop

      assert_equal 1, cell.log_events("cell.ptrace_scope_unknown").size
    end
  end

  # The mode on the socket is the access control on speaking to a cell, and the group is what grants it.
  # World write would give both sockets away to anything else sharing either container.
  def test_the_sockets_admit_the_cells_group_and_nobody_else
    TestCell.boot do |cell|
      %w[ work.sock control.sock ].each do |name|
        mode = File.stat(File.join(cell.directory, name)).mode & 0o777

        assert_equal 0o660, mode, "#{name} is #{mode.to_s(8)}"
      end
    end
  end

  def test_a_socket_path_too_long_for_the_platform_says_which_limit_it_broke
    supervisor = HotCell::Supervisor.new(directory: "/tmp/#{"d" * 200}", log: HotCell::Log.null)

    error = assert_raises(HotCell::ConfigurationError) { supervisor.boot }

    assert_match "a Unix socket path on this platform holds", error.message
    assert_match "Choose a shorter directory", error.message
  end

  def test_a_limit_above_this_processs_hard_limit_says_so_rather_than_failing_in_a_worker
    _soft, hard = Process.getrlimit(Process::RLIMIT_NOFILE)
    skip "this process has no finite descriptor limit" if hard == Process::RLIM_INFINITY

    error = assert_raises RuntimeError do
      HotCell::TestCell.boot(open_files: hard + 1) { nil }
    end

    assert_match "is above this process's hard limit", error.message
  end

  def test_a_cell_logs_its_inventory_and_its_limits_at_boot
    TestCell.boot(concurrency: 2) do |cell|
      cell.stop
      booted = cell.log_events("cell.boot").first

      assert_equal 2, booted[:concurrency]
      assert_includes booted[:operations], "test.uppercase"
    end
  end

  # The worker tells the supervisor when its operation asked for less than the cell allows, because the
  # supervisor never reads a request and cannot know. It may only narrow. The worker is the one process here
  # that runs untrusted code, so the number it reports is checked rather than trusted: this is the side that
  # owns invariant 6.
  def test_the_supervisor_narrows_a_reported_deadline_and_never_widens_it
    supervisor = HotCell::Supervisor.new(directory: "/tmp/unused", log: HotCell::Log.null,
                                         configuration: HotCell::Configuration.new(deadline: 30))

    assert_equal 5, supervisor.send(:narrowed_deadline, 5)
    assert_equal 30, supervisor.send(:narrowed_deadline, 3000)
    assert_equal 30, supervisor.send(:narrowed_deadline, nil)
    assert_equal 30, supervisor.send(:narrowed_deadline, 0)
    assert_equal 30, supervisor.send(:narrowed_deadline, -1)
    assert_equal 30, supervisor.send(:narrowed_deadline, "forever")
  end

  private
end
