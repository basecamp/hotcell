# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "socket"
require "json"

require "hot_cell/server"

require_relative "support/operations"
require_relative "support/test_cell"

class HotCellServerTest < Minitest::Test
  private
    def with_file(contents = "")
      Tempfile.create([ "hotcell", ".bin" ], binmode: true) do |file|
        file.write contents
        file.flush
        yield file.path
      end
    end

    # A source and a destination, which is the shape of most requests.
    def with_files(contents = "source bytes")
      with_file(contents) { |source| with_file { |destination| yield source, destination } }
    end

    def assert_ok(response)
      assert response, "expected a response and got none"
      assert response.ok?, "expected ok and got #{response.failure&.to_s.inspect}"
      response
    end

    # A cell writes its log and removes its scratch after it has answered, so a few properties are
    # genuinely asynchronous with respect to the caller. Bounded polling says so; a sleep would not.
    def wait_until(within: 5, what: "the condition")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within

      until yield
        flunk "#{what} did not happen within #{within}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
    end

    def elapsed
      at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - at
    end

    def assert_failed(code, response, limit: nil)
      assert response, "expected a response and got none"
      refute response.ok?, "expected #{code} and the response was ok: #{response.result.inspect}"
      assert_equal code, response.failure.code
      assert_equal limit, response.failure.limit if limit

      response.failure
    end
end

# The registry is process-wide, and the fixture operations are registered once at load. A test that adds or
# renames operations has to put it back.
class RegistryIsolatedTest < HotCellServerTest
  def setup
    @registered = HotCell::Registry.operations.dup
  end

  def teardown
    HotCell::Registry.clear
    @registered.each { |operation| HotCell::Registry.register operation }
  end
end
