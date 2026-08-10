# frozen_string_literal: true

require "test_helper"

# Descriptor access modes are one-way: an input cannot be written and an output cannot be read. That is
# invariant 4, and it is worth testing because the kernel owns it. An access mode is fixed at open, so a
# cell handed the wrong one cannot correct it, only decline the request.
class DescriptorsTest < HotCellTest
  def test_an_input_takes_a_read_only_descriptor
    with_file("bytes") do |path|
      reading(path) { |io| assert_equal "bytes", HotCell::Input.new(io).to_io.read }
    end
  end

  def test_an_input_refuses_a_read_write_descriptor
    with_file do |path|
      updating(path) do |io|
        error = assert_raises(HotCell::AccessModeError) { HotCell::Input.new(io) }

        assert_match "needs a read-only descriptor, and this one is read-write", error.message
      end
    end
  end

  def test_an_input_refuses_a_write_only_descriptor
    with_file do |path|
      writing(path) { |io| assert_raises(HotCell::AccessModeError) { HotCell::Input.new(io) } }
    end
  end

  def test_an_output_takes_a_write_only_descriptor
    with_file do |path|
      writing(path) { |io| assert_instance_of HotCell::Output, HotCell::Output.new(io) }
    end
  end

  def test_an_output_refuses_a_read_write_descriptor
    with_file do |path|
      updating(path) do |io|
        error = assert_raises(HotCell::AccessModeError) { HotCell::Output.new(io) }

        assert_match "needs a write-only descriptor, and this one is read-write", error.message
      end
    end
  end

  def test_an_output_refuses_a_read_only_descriptor
    with_file do |path|
      reading(path) { |io| assert_raises(HotCell::AccessModeError) { HotCell::Output.new(io) } }
    end
  end

  # A single streaming write to a pipe can deadlock against a cold side that is not draining it.
  def test_a_pipe_is_not_a_descriptor_this_protocol_carries
    IO.pipe do |readable, writable|
      assert_raises(HotCell::AccessModeError) { HotCell::Input.new(readable) }

      error = assert_raises(HotCell::AccessModeError) { HotCell::Output.new(writable) }
      assert_match "needs a regular file, and this one is a fifo", error.message
    end
  end

  def test_asking_an_input_for_its_path_copies_its_bytes_to_a_filename_the_cold_side_never_named
    with_file("source bytes") do |source|
      Dir.mktmpdir do |scratch|
        reading(source) do |io|
          input = HotCell::Input.new(io, scratch: -> { File.join(scratch, "input") })

          refute_predicate input, :staged?
          assert_equal "source bytes", File.binread(input.path)
          assert_predicate input, :staged?
        end
      end
    end
  end

  def test_an_input_copies_once_and_answers_the_same_path_after_that
    with_file("source bytes") do |source|
      Dir.mktmpdir do |scratch|
        reading(source) do |io|
          named = 0
          locate = lambda do
            named += 1
            File.join(scratch, "input")
          end

          input = HotCell::Input.new(io, scratch: locate)

          assert_equal input.path, input.path
          assert_equal 1, named
        end
      end
    end
  end

  def test_a_descriptor_with_no_scratch_has_no_path
    with_file("bytes") do |source|
      reading(source) do |io|
        error = assert_raises(HotCell::Error) { HotCell::Input.new(io).path }

        assert_match "has no scratch", error.message
      end
    end
  end

  def test_an_unstaged_descriptor_says_so
    with_file do |path|
      reading(path) { |io| refute_predicate HotCell::Input.new(io), :staged? }
    end
  end

  def test_posting_a_staged_output_sends_what_the_operation_wrote_and_reports_the_count
    with_file do |destination|
      Dir.mktmpdir do |scratch|
        writing(destination) do |io|
          output = HotCell::Output.new(io, scratch: -> { File.join(scratch, "output") })
          File.binwrite output.path, "converted"

          assert_equal 9, output.post
        end

        assert_equal "converted", File.binread(destination)
      end
    end
  end

  # Zero bytes is a verdict the client already has to handle, because a full tmpfs arrives the same way.
  def test_posting_a_staged_output_the_operation_never_wrote_reports_zero
    with_file do |destination|
      Dir.mktmpdir do |scratch|
        writing(destination) do |io|
          output = HotCell::Output.new(io, scratch: -> { File.join(scratch, "never-written") })
          output.path

          assert_equal 0, output.post
        end
      end
    end
  end

  def test_posting_an_unstaged_output_flushes_and_reports_what_is_there
    with_file do |destination|
      writing(destination) do |io|
        output = HotCell::Output.new(io)
        output.to_io.write "written directly"

        assert_equal 16, output.post
      end

      assert_equal "written directly", File.binread(destination)
    end
  end

  def test_closing_twice_is_harmless
    with_file do |path|
      reading(path) do |io|
        input = HotCell::Input.new(io)
        input.close
        input.close

        assert_predicate io, :closed?
      end
    end
  end

  # The same class of caller bug as a read-write descriptor, and just as quiet: every write lands at the end
  # whatever the cell does, so the caller reads its old bytes followed by the conversion.
  def test_an_output_opened_for_append_is_refused
    with_file("already here") do |path|
      File.open(path, "ab") do |appending|
        error = assert_raises(HotCell::AccessModeError) { HotCell::Output.new(appending) }

        assert_match "O_APPEND", error.message
      end
    end
  end

  def test_an_ordinary_write_only_output_is_fine
    with_file do |path|
      writing(path) { |io| assert HotCell::Output.new(io) }
    end
  end
end
