# frozen_string_literal: true

require "test_helper"

# The property the whole process model rests on, and the one whose violation is a silent hang rather than a
# crash.
#
# libvips starts its thread pool on the first evaluation. That pool does not survive fork, so a child forked
# afterwards waits on a pool with no threads. Not the first child — every child. This is why an operation's
# before_fork may require and configure but must never evaluate, and why nothing in this suite loads libvips into
# the test process.
#
# Both directions are checked. A test that only showed the good case would not establish that the hazard is real,
# and it is the reality of the hazard that justifies the whole arrangement.
class ForkSafetyTest < ActiveStorageHotCellTest
  # Runs in a child of this process, so that neither arm can poison the suite.
  def test_a_process_that_only_required_libvips_forks_children_that_convert
    assert_equal "ok", in_a_subprocess { |probe| probe.puts "convert_after_require" }
  end

  def test_a_process_that_evaluated_one_image_forks_children_that_deadlock
    assert_equal "deadlocked", in_a_subprocess { |probe| probe.puts "convert_after_evaluating" }
  end

  # And the arrangement holds end to end: a real cell converts, request after request, because the supervisor
  # only ever requires and configures.
  def test_a_real_cell_converts_request_after_request
    Cell.boot(max_requests_per_worker: 1, concurrency: 1) do |cell|
      3.times do
        with_output do |destination|
          assert_ok cell.call("active_storage.transform_image",
                              inputs: [ fixture("colour.png") ], outputs: [ destination ],
                              payload: { format: "png", operations: { resize_to_limit: [ 20, 20 ] } })
        end
      end
    end
  end

  private
    PROBE = <<~RUBY
      require "image_processing/vips"
      Vips.block_untrusted true
      source = ARGV[0]

      def convert_in_child
        read, write = IO.pipe
        pid = fork do
          read.close
          Thread.new { sleep 5; write.write "deadlocked"; write.close; exit! 1 }
          ImageProcessing::Vips.source(ARGV[0]).loader(page: 0).convert("png")
            .apply(resize_to_limit: [ 20, 20 ]).call.close!
          write.write "ok"
          write.close
          exit! 0
        end
        write.close
        answer = read.read
        read.close
        Process.wait pid
        answer
      end

      case $stdin.gets.chomp
      when "convert_after_require"
        puts convert_in_child
      when "convert_after_evaluating"
        Vips::Image.black(1, 1).avg
        puts convert_in_child
      end
    RUBY

    def in_a_subprocess
      IO.popen([ RbConfig.ruby, "-e", PROBE, fixture("colour.png") ], "r+") do |probe|
        yield probe
        probe.close_write
        probe.read.to_s.strip
      end
    end
end
