# frozen_string_literal: true

require "test_helper"

# The boot contract: config.rb loads first, explicitly, and the operations follow in sorted order. The
# configuration is not an operations file that happens to sort to the front.
class LoadTest < HotCellServerTest
  def teardown
    self.class.order.clear
  end

  def test_the_config_file_loads_before_any_operation
    Dir.mktmpdir do |root|
      File.write File.join(root, "config.rb"), "LoadTest.order << :config"
      operations = operations_dir(root, "alpha.rb" => "LoadTest.order << :alpha")

      HotCell.load! config: File.join(root, "config.rb"), operations: operations

      assert_equal [ :config, :alpha ], self.class.order
    end
  end

  def test_a_cell_with_no_config_file_boots_without_one
    Dir.mktmpdir do |root|
      operations = operations_dir(root, "alpha.rb" => "LoadTest.order << :alpha")

      HotCell.load! config: File.join(root, "config.rb"), operations: operations

      assert_equal [ :alpha ], self.class.order
    end
  end

  def test_operations_load_in_sorted_order
    Dir.mktmpdir do |root|
      operations = operations_dir(root, "beta.rb" => "LoadTest.order << :beta",
                                        "alpha.rb" => "LoadTest.order << :alpha")

      HotCell.load! config: File.join(root, "config.rb"), operations: operations

      assert_equal [ :alpha, :beta ], self.class.order
    end
  end

  def self.order
    @order ||= []
  end

  private
    def operations_dir(root, files)
      File.join(root, "operations").tap do |operations|
        FileUtils.mkdir_p operations
        files.each { |name, content| File.write File.join(operations, name), content }
      end
    end
end
