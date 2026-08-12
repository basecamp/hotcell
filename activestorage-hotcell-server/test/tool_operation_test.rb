# frozen_string_literal: true

require "test_helper"
require "active_storage/hot_cell/server/tool_operation"

# The two ways a tool fails without saying so: exiting non-zero, and exiting zero having written nothing.
# Both must become `unreadable` — anything else means the client reads success with no bytes, reclassifies
# it as transient, and retries a permanent condition for every attempt the job allows.
class ToolOperationTest < ActiveStorageHotCellTest
  # Abstract, deliberately: a concrete subclass registers itself in the process-wide registry, and the
  # inventory test asserts exactly what a real cell carries.
  class Probe < ActiveStorage::HotCell::Server::ToolOperation
    abstract_operation
  end

  UnreadableDocument = ActiveStorage::HotCell::Server::ToolOperation::UnreadableDocument

  def test_a_tool_that_exits_nonzero_is_unreadable_and_names_the_tool
    error = assert_raises UnreadableDocument do
      operation.send :run!, "false"
    end

    assert_match "false exited 1", error.message
  end

  def test_a_tool_that_succeeds_and_writes_nothing_is_unreadable
    with_file do |path|
      error = assert_raises UnreadableDocument do
        operation.send :produced!, path, "mutool"
      end

      assert_match "mutool wrote nothing", error.message
    end
  end

  def test_an_output_the_tool_never_created_is_unreadable
    error = assert_raises UnreadableDocument do
      operation.send :produced!, "/nonexistent/output.png", "mutool"
    end

    assert_match "wrote nothing", error.message
  end

  def test_an_output_with_bytes_reports_its_size
    with_file "some pixels" do |path|
      assert_equal 11, operation.send(:produced!, path, "mutool")
    end
  end

  private
    def operation
      Probe.new
    end

    def with_file(contents = "")
      Tempfile.create([ "tool", ".bin" ], binmode: true) do |file|
        file.write contents
        file.flush
        yield file.path
      end
    end
end
