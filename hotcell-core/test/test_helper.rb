# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "socket"

require "hot_cell/core"

class HotCellTest < Minitest::Test
  private
    # Descriptors have to be regular files, so every fixture is a real file on disk.
    def with_file(contents = "")
      Tempfile.create([ "hotcell", ".bin" ], binmode: true) do |file|
        file.write contents
        file.flush
        yield file.path
      end
    end

    def reading(path, &block)
      File.open path, "rb", &block
    end

    def writing(path, &block)
      File.open path, "wb", &block
    end

    def updating(path, &block)
      File.open path, "r+b", &block
    end

    def open_descriptors
      skip "counting open descriptors needs Linux" unless File.directory?("/proc/self/fd")
      Dir.children("/proc/self/fd").size
    end
end
