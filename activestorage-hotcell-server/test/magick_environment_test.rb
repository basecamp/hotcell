# frozen_string_literal: true

require "test_helper"

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

  private
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
