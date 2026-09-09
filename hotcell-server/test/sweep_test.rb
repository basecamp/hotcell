# frozen_string_literal: true

require "test_helper"

# The supervisor renames a killed worker's tree aside and a worker sweeps it once it has answered — but a
# worker killed at its deadline never reaches that sweep, so a slot whose every request is killed stacked
# one tree per kill until the scratch was full. The sweeper is a child the supervisor forks on a timer to
# do that unlinking off every hot path, under a deadline of its own so a tree that will not go cannot hold
# the next sweep off forever.
class SweepTest < HotCellServerTest
  def test_a_killed_workers_tree_is_swept_with_no_request_to_do_it
    TestCell.boot(deadline: 0.2, concurrency: 1, sweep_interval: 0.1) do |cell|
      assert_failed "killed", cell.call("test.uninterruptible", timeout: 20), cause: "deadline"

      wait_until(what: "the discarded tree to be swept") { Dir.glob(discarded(cell)).empty? }

      swept = wait_for_event(cell, "scratch.swept")
      assert_equal 1, swept.sum { |event| event[:hotcell][:swept] }
    end
  end

  def test_the_sweeper_does_not_fork_while_nothing_is_discarded
    TestCell.boot(concurrency: 1, sweep_interval: 0.05) do |cell|
      assert_ok cell.call("test.echo")
      sleep 0.3

      assert_empty cell.log_events("sweeper.forked")
    end
  end

  # SIGSTOP stands in for a tree whose size an input chose: a sweeper that cannot finish is killed at the
  # deadline, and the next tick forks another rather than waiting on it.
  def test_a_sweeper_that_does_not_finish_is_killed_at_the_deadline_and_replaced
    TestCell.boot(deadline: 0.3, concurrency: 1, sweep_interval: 0.1) do |cell|
      plant_large_tree cell

      forked = wait_for_event(cell, "sweeper.forked")
      refute_empty forked, "no sweeper was forked for the planted tree"
      Process.kill :STOP, forked.first[:process][:pid]

      killed = wait_for_event(cell, "sweeper.deadline")
      assert_equal 0.3, killed.first[:hotcell][:deadline_s]

      wait_until(within: 10, what: "a later sweeper to finish the job") { Dir.glob(discarded(cell)).empty? }
      assert_operator cell.log_events("sweeper.forked").size, :>=, 2, "no second sweeper was forked"
    end
  end

  # A sweeper the supervisor did not kill can still die by signal — the cgroup's OOM killer, or a sibling
  # worker sharing its uid — and a death that left only `sweeper.forked` behind was indistinguishable from
  # a sweep that finished.
  def test_a_sweeper_that_dies_by_signal_is_reported_and_the_next_tick_tries_again
    TestCell.boot(concurrency: 1, sweep_interval: 0.1) do |cell|
      plant_large_tree cell

      forked = wait_for_event(cell, "sweeper.forked")
      refute_empty forked, "no sweeper was forked for the planted tree"
      Process.kill :KILL, forked.first[:process][:pid]

      died = wait_for_event(cell, "sweeper.died")
      assert_equal "KILL", died.first[:hotcell][:signal]

      wait_until(within: 10, what: "a later sweeper to finish the job") { Dir.glob(discarded(cell)).empty? }
    end
  end

  private
    def discarded(cell)
      File.join(cell.workspace, "0", "discarded-*")
    end

    def plant_large_tree(cell)
      staging = File.join(cell.workspace, "0", "planting")
      FileUtils.mkdir_p staging
      20_000.times { |index| File.write File.join(staging, index.to_s), "" }
      File.rename staging, File.join(cell.workspace, "0", "discarded-planted")
    end
end
