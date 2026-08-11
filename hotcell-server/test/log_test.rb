# frozen_string_literal: true

require "test_helper"
require "fcntl"

# The log sink is a pipe to the container runtime, and the supervisor writes to it inside the loop that
# enforces every request's deadline. A runtime that stops draining must not be able to park that loop.
class LogTest < HotCellServerTest
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
