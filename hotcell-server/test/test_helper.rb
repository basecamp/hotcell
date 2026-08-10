# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "socket"
require "json"

require "hot_cell/server"
require "hot_cell/test_support"

require "hot_cell/test_operations"
require_relative "support/test_cell"

# The fixtures ship namespaced; these suites read better without the prefix.
Fixtures = HotCell::Fixtures

class HotCellServerTest < Minitest::Test
  include HotCell::TestSupport

  private
    def assert_ok(response)
      assert response, "expected a response and got none"
      assert_predicate response, :ok?, "expected ok and got #{response.failure&.to_s.inspect}"
      response
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
