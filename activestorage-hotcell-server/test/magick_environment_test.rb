# frozen_string_literal: true

require "test_helper"
require "etc"

# Invariant 9: a tool sees only the environment its operation wrote for it. `Operation#run_tool` holds it
# with `unsetenv_others: true`, and the magick operations do not use it — mini_magick spawns `magick`
# itself, and it inherited this worker's whole environment until `MiniMagick.restricted_env` was set.
#
# `bin/conformance` checks the same invariant against an operation that goes through `run_tool`, so it
# cannot see this half of it. Neither can the rest of this suite: every other magick test passes whether
# the child inherits the environment or not. That is the definition of a control worth testing.
#
# `MAGICK_CONFIGURE_PATH` is the lever because it is one ImageMagick reads from its own environment and
# acts on. A policy there that refuses PNG makes the difference visible as a refusal rather than as a
# string a test has to trust: a `magick` that inherits the variable cannot read the fixture, and one that
# does not read it decodes normally. The cell is forked from this process, so the variable reaches the
# worker.
class MagickEnvironmentTest < ActiveStorageHotCellTest
  def test_magick_does_not_inherit_the_workers_environment
    with_refusing_policy_in_the_environment do
      Cell.boot do |cell|
        response = cell.call "active_storage.analyzers.image.magick", inputs: [ fixture("colour.png") ]

        assert_ok response
        assert_operator response.result[:width], :>, 0
      end
    end
  end

  # The premise. Handed the same variable, `magick` in this process does refuse the fixture — so the
  # assertion above cannot pass because the policy was ineffective.
  def test_the_policy_does_refuse_a_magick_that_reads_it
    with_refusing_policy_in_the_environment do |directory|
      refused = system({ "MAGICK_CONFIGURE_PATH" => directory }, "magick", "identify", fixture("colour.png"),
                       out: File::NULL, err: File::NULL)

      refute refused, "the policy did not refuse PNG, so this test proves nothing"
    end
  end

  # `magick` sees only the environment mini_magick writes for it, so the image's OpenMP bound has to be
  # named in `cli_env`; the restriction above is otherwise what takes it away.
  def test_the_cli_env_carries_the_cells_openmp_bound
    bound = { "OMP_NUM_THREADS" => "2", "OMP_THREAD_LIMIT" => "8" }

    assert_equal bound, magick_cli_env_under(bound)
    assert_empty magick_cli_env_under({}), "the cell invented a bound of its own"
  end

  # mini_magick, rather than our hash: it is unbounded in the gemspec, and a version that stopped merging
  # `cli_env` would leave the assertion above passing and `magick` unbounded again.
  def test_mini_magick_hands_the_bound_to_magick
    skip "ImageMagick is not installed" unless magick_installed?
    skip "a #{Etc.nprocessors}-core host cannot tell a bounded pool from an unbounded one" if
      Etc.nprocessors < 4

    assert_operator magick_threads_through_mini_magick("OMP_NUM_THREADS" => "2"), :<,
                    magick_threads_through_mini_magick({})
  end

  # The premise: `magick` reads OMP_NUM_THREADS out of the environment it is given, so naming it in
  # `cli_env` bounds a real pool.
  def test_magick_reads_an_openmp_bound_out_of_its_environment
    skip "a #{Etc.nprocessors}-core host cannot tell a bounded pool from an unbounded one" if
      Etc.nprocessors < 4

    assert_operator magick_thread_resource("OMP_NUM_THREADS" => "2"), :<, magick_thread_resource({})
  end

  # The cell sets `TMPDIR` to the request's home and nothing else; ImageMagick reads `MAGICK_TMPDIR`. An
  # operation maps one to the other when it is instantiated, which is once per request — a mapping made at
  # load would name the cell's `/tmp`, since no request has a home yet.
  def test_an_operation_points_imagemagick_at_the_requests_tmpdir
    output = in_a_child({}, <<~'RUBY')
      require "json"
      require "active_storage/hot_cell/server"
      at_load = ENV["MAGICK_TMPDIR"]
      ENV["TMPDIR"] = "/scratch/home-for-this-request"
      ActiveStorage::HotCell::Server::Analyzers::Image::Magick.new
      puts JSON.dump([ at_load, ENV["MAGICK_TMPDIR"] ])
    RUBY

    assert_equal [ nil, "/scratch/home-for-this-request" ], JSON.parse(output)
  end

  private
    def magick_cli_env_under(environment)
      JSON.parse in_a_child(environment, <<~RUBY)
        require "json"
        require "active_storage/hot_cell/server/magick_operation"
        puts JSON.dump(MiniMagick.cli_env.slice("OMP_NUM_THREADS", "OMP_THREAD_LIMIT"))
      RUBY
    end

    # Through mini_magick's own spawn rather than IO.popen, which is the whole point: what mini_magick
    # merges into that child is what the assertion is about. Nothing here rescues, so a child that cannot
    # run fails the test rather than reading as a bound of zero.
    def magick_threads_through_mini_magick(environment)
      output = in_a_child(environment, <<~'RUBY')
        require "active_storage/hot_cell/server/magick_operation"
        print MiniMagick.convert { |command| command.list "resource" }[/Thread: (\d+)/, 1]
      RUBY

      Integer(output)
    end

    # The operation reads the variables at require time, so each case needs its own process. A developer's
    # own shell may hold either, so the child starts from neither and takes only what the case gives it.
    def in_a_child(environment, script)
      environment = { "OMP_NUM_THREADS" => nil, "OMP_THREAD_LIMIT" => nil, "MAGICK_TMPDIR" => nil }.merge(environment)
      lib = File.expand_path("../lib", __dir__)

      IO.popen([ environment, RbConfig.ruby, "-I", lib, "-r", "bundler/setup", "-e", script ], &:read)
    end

    # Both sides start from no bound at all: a runner holding one of its own would otherwise compare a
    # bounded pool against a bounded pool.
    def magick_installed?
      system "magick", "-version", out: File::NULL, err: File::NULL
    rescue Errno::ENOENT
      false
    end

    def magick_thread_resource(environment)
      environment = { "OMP_NUM_THREADS" => nil, "OMP_THREAD_LIMIT" => nil }.merge(environment)
      output = IO.popen([ environment, "magick", "-list", "resource" ], &:read)

      Integer(output[/Thread: (\d+)/, 1])
    rescue Errno::ENOENT
      skip "ImageMagick is not installed"
    end

    def with_refusing_policy_in_the_environment
      Dir.mktmpdir "hotcell-magick-policy" do |directory|
        File.write File.join(directory, "policy.xml"), <<~XML
          <policymap>
            <policy domain="coder" rights="none" pattern="PNG" />
          </policymap>
        XML

        original = ENV["MAGICK_CONFIGURE_PATH"]
        ENV["MAGICK_CONFIGURE_PATH"] = directory
        begin
          yield directory
        ensure
          ENV["MAGICK_CONFIGURE_PATH"] = original
        end
      end
    end
end
