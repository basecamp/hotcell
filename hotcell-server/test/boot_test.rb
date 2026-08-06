# frozen_string_literal: true

require "test_helper"

# A cell that is configured wrongly has to say so at boot. Two of these are refusals rather than warnings,
# because both would otherwise be silent: a host sysctl is invisible to the image, and a framework loaded by
# a transitive require looks like nothing at all.
class BootTest < RegistryIsolatedTest
  # Request memory is protected by kernel.yama.ptrace_scope and by nothing else. No container flag can set
  # it, so a cell that finds it off has lost the guarantee, and a warning in a log is how a dead control
  # stays dead.
  def test_a_host_where_a_worker_could_read_a_siblings_memory_refuses_to_boot
    with_ptrace_scope "0" do |path|
      error = assert_raises(RuntimeError) { HotCell::TestCell.boot(supervisor: { ptrace_scope_path: path }) { nil } }

      assert_match "kernel.yama.ptrace_scope is 0", error.message
      assert_match "No container flag can set it", error.message
    end
  end

  def test_a_protected_host_boots
    with_ptrace_scope "1" do |path|
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

  # Invariant 1. The thing that breaks it is a transitive require in somebody's operation rather than
  # anything in this gem, so it is checked after the operations have been read in.
  def test_a_cell_that_loaded_an_application_framework_refuses_to_boot
    Class.new(HotCell::Operation) do
      operation "boot_test.drags_in_a_framework"
      before_fork { Object.const_set(:ActiveStorage, Module.new).const_set(:Blob, Class.new) }
    end

    error = assert_raises(RuntimeError) { HotCell::TestCell.boot { nil } }

    assert_match "ActiveStorage is loaded in this cell", error.message
    assert_match "a cell holds neither", error.message.downcase
  end

  # The check is keyed on a constant only the framework defines, not on the top-level name. A gem that serves
  # Active Storage may namespace itself under ActiveStorage without linking against it, which is exactly what
  # activestorage-hotcell-server does — its name says which consumer it serves, not what it loads.
  def test_an_operation_may_namespace_itself_under_a_frameworks_name_without_loading_it
    Class.new(HotCell::Operation) do
      operation "boot_test.borrows_the_name"
      before_fork { Object.const_set :ActiveStorage, Module.new }
    end

    TestCell.boot { |cell| assert_ok cell.call("test.echo") }
  ensure
    Object.send :remove_const, :ActiveStorage if Object.const_defined?(:ActiveStorage)
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

  def test_a_cell_logs_its_consist_and_its_limits_at_boot
    TestCell.boot(concurrency: 2) do |cell|
      cell.stop
      booted = cell.log_events("cell.boot").first

      assert_equal 2, booted[:concurrency]
      assert_includes booted[:operations], "test.uppercase"
    end
  end

  # Supported, often right, and it must not be made silently by somebody adding an operation to an existing
  # cell. So it is a line in the log naming what is given up, not a refusal.
  def test_reuse_above_one_with_in_process_parsing_warns_and_serves_anyway
    TestCell.boot(reuse: 3) do |cell|
      assert_ok cell.call("test.echo")
      cell.stop

      warning = cell.log_events("cell.reuse_warning").first
      assert_match "reuse: 3", warning[:warning]
      assert_match "test.uppercase", warning[:warning]
    end
  end

  def test_reuse_of_one_has_nothing_to_warn_about
    TestCell.boot do |cell|
      assert_ok cell.call("test.echo")
      cell.stop

      assert_empty cell.log_events("cell.reuse_warning")
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
    def with_ptrace_scope(value)
      Tempfile.create("ptrace_scope") do |file|
        file.write value
        file.flush
        yield file.path
      end
    end
end
