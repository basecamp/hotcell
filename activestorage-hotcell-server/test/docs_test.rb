# frozen_string_literal: true

require "test_helper"

# The reference pages describe behavior, and this fails when the limits table there stops matching the code.
class DocsTest < ActiveStorageHotCellTest
  DOCS = File.expand_path("../../docs", __dir__)
  OPERATIONS = File.expand_path("../lib/active_storage/hot_cell/server", __dir__)

  def test_the_limits_table_carries_each_shipped_operations_limits
    assert_equal declared_limits, documented_limits
  end

  private
    # In a child process, because requiring the operations loads libvips, and libvips in this process would
    # deadlock every cell the rest of the suite forks.
    def declared_limits
      script = <<~RUBY
        require "json"
        Dir[#{File.join(OPERATIONS, "{transformers,analyzers,previewers}", "**", "*.rb").inspect}].each { |file| require file }
        concrete = HotCell::Registry.operations.reject(&:abstract_operation?)
        puts JSON.generate(concrete.to_h { |operation| [ operation.operation_name, operation.limits.to_h ] })
      RUBY
      output = IO.popen([ RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script ], &:read)
      assert_predicate $?, :success?

      JSON.parse(output).transform_values { |limits| limits.transform_keys(&:to_sym) }
    end

    def documented_limits
      lines = File.readlines(File.join(DOCS, "active-storage.md"), chomp: true)
      lines = lines.drop_while { |line| line != "## Limits" }
      header = lines.index { |line| line.start_with?("| Routing name |") }

      lines.drop(header + 2).take_while { |line| line.start_with?("|") }.to_h do |line|
        name, deadline, memory, file_size, open_files = line.delete_prefix("|").delete_suffix("|").split(" | ").map(&:strip)

        [ name.delete("`"), { deadline: Float(deadline), memory: megabytes(memory), file_size: megabytes(file_size),
                              open_files: Integer(open_files) } ]
      end
    end

    def megabytes(text)
      Integer(text.delete_suffix("MB")) * 1024**2
    end
end
