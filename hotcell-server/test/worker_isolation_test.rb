# frozen_string_literal: true

require "test_helper"

# Every worker runs as the same uid, so without more a sibling reads a worker's /proc entries the way it reads
# its own. The test process stands in for the sibling: it has the worker's uid and is not root.
class WorkerIsolationTest < HotCellServerTest
  # A second allowed request keeps the worker alive, past `become_worker`, to be looked at.
  def test_a_process_with_the_workers_uid_cannot_reach_its_descriptors
    skip "reading another process's descriptors needs procfs" unless File.directory?("/proc/self/fd")
    skip "root reads every process's descriptors" if Process.uid.zero?

    TestCell.boot(concurrency: 1, max_requests_per_worker: 2) do |cell|
      worker = assert_ok(cell.call("test.whoami")).result[:pid]
      supervisor = cell.log_events("cell.boot").first.dig(:process, :pid)

      # The premise first: the same uid reaches a process that is not a worker, so the refusal means something.
      Dir.children "/proc/#{supervisor}/fd"

      assert_raises(Errno::EACCES) { Dir.children "/proc/#{worker}/fd" }
    end
  end
end
