# frozen_string_literal: true

require "test_helper"
require "fcntl"

# The log sink is a pipe to the container runtime, and the supervisor writes to it inside the loop that
# enforces every request's deadline. A runtime that stops draining must not be able to park that loop.
#
# The line format is the schema in docs/LOGS.md. The fleet's log collector routes on service.name,
# takes the record timestamp from @timestamp, and severity from log.level, so those three are
# load-bearing: a rename silently drops or mislabels every cell log line in production.
class LogTest < HotCellServerTest
  def test_every_line_carries_the_envelope
    line = written "worker.forked", pid: 42, slot: 3

    assert_equal "hotcell", line.dig(:service, :name)
    assert_equal "worker.forked", line.dig(:event, :action)
    assert_equal "INFO", line.dig(:log, :level)
    assert_equal 42, line.dig(:process, :pid)
    assert_in_delta Time.now.utc, Time.iso8601(line[:"@timestamp"]), 5
  end

  def test_each_event_declares_its_own_level
    assert_equal "ERROR", written("worker.crashed", slot: 0).dig(:log, :level)
    assert_equal "WARN", written("worker.killed", slot: 0).dig(:log, :level)
    assert_equal "INFO", written("request", slot: 0).dig(:log, :level)
  end

  def test_an_unknown_event_is_info_rather_than_unloggable
    assert_equal "INFO", written("someday.new").dig(:log, :level)
  end

  def test_an_exception_becomes_error_type_and_error_message
    line = written "worker.crashed", slot: 0, error: "NoMethodError", message: "undefined method"

    assert_equal "NoMethodError", line.dig(:error, :type)
    assert_equal "undefined method", line.dig(:error, :message)
    assert_nil line[:message]
  end

  def test_prose_without_an_exception_becomes_the_message
    line = written "slot.uncleaned", slot: 0, message: "an earlier boot's files are still here"

    assert_equal "an earlier boot's files are still here", line[:message]
    assert_nil line[:error]
  end

  def test_a_duration_and_an_outcome_land_under_event
    line = written "request", slot: 0, code: "ok", outcome: "success", duration_ms: 9.6

    assert_equal "success", line.dig(:event, :outcome)
    assert_in_delta 9.6, line.dig(:event, :duration, :ms)
  end

  def test_an_exit_code_lands_under_process
    line = written "worker.reaped", pid: 42, slot: 0, exit_code: 1

    assert_equal 42, line.dig(:process, :pid)
    assert_equal 1, line.dig(:process, :exit_code)
  end

  def test_domain_fields_nest_under_the_hotcell_namespace
    line = written "worker.killed", pid: 42, slot: 3, cause: "memory", signal: "SIGKILL",
                                    timing: { queued_ms: 0.4 }

    assert_equal 3, line.dig(:hotcell, :slot)
    assert_equal "memory", line.dig(:hotcell, :cause)
    assert_equal "SIGKILL", line.dig(:hotcell, :signal)
    assert_in_delta 0.4, line.dig(:hotcell, :timing, :queued_ms)
    assert_nil line[:slot], "domain fields must not leak to the top level"
  end

  def test_fields_that_cannot_serialize_still_produce_a_line
    line = written "worker.crashed", slot: 0, broken: Float::NAN

    assert_equal "worker.crashed", line.dig(:event, :action)
    assert_equal %w[slot broken], line.dig(:hotcell, :unloggable)
  end

  def test_a_full_log_pipe_drops_the_line_rather_than_blocking_the_writer
    reader, writer = IO.pipe
    fill_pipe writer
    log = HotCell::Log.new(writer)

    writing = Thread.new { log.write "stalled", filler: "y" * 200 }

    assert writing.join(2), "log.write blocked on a full pipe instead of dropping the line"
  ensure
    reader&.close
    writing&.join(1)
    writing&.kill
    writer&.close
  end

  private
    def written(event, **fields)
      reader, writer = IO.pipe
      HotCell::Log.new(writer).write event, **fields
      writer.close
      JSON.parse reader.read, symbolize_names: true
    ensure
      reader&.close
    end

    # Fills the pipe so the next write has nowhere to go, and restores blocking mode so a naive write would
    # park on the full pipe rather than raise.
    def fill_pipe(writer)
      flags = writer.fcntl(Fcntl::F_GETFL)
      writer.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)

      begin
        loop { writer.write_nonblock("x" * 4096) }
      rescue IO::WaitWritable
        nil
      end

      writer.fcntl(Fcntl::F_SETFL, flags)
    end
end
