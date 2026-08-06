# frozen_string_literal: true

require "test_helper"

class CellTest < HotCellServerTest
  def test_a_conversion_crosses_the_boundary_and_comes_back
    TestCell.boot do |cell|
      with_files("hello from the cold side") do |source, destination|
        response = cell.call "test.uppercase", inputs: [ source ], outputs: [ destination ]

        assert_ok response
        assert_equal "HELLO FROM THE COLD SIDE", File.binread(destination)
        assert_equal 24, response.result[:bytes]
      end
    end
  end

  def test_timing_breaks_down_where_the_time_went
    TestCell.boot do |cell|
      with_files do |source, destination|
        timing = assert_ok(cell.call("test.uppercase", inputs: [ source ], outputs: [ destination ])).timing

        [ :queued_ms, :staging_ms, :convert_ms, :writeback_ms, :perform_ms ].each do |key|
          assert timing.key?(key), "expected #{key} in #{timing.inspect}"
        end
        assert_operator timing[:perform_ms], :>=, timing[:convert_ms]
      end
    end
  end

  def test_several_inputs
    TestCell.boot do |cell|
      with_file("one") do |first|
        with_file("two") do |second|
          with_file do |destination|
            response = cell.call "test.concatenate", inputs: [ first, second ],
                                                     outputs: [ destination ], payload: { separator: "+" }

            assert_ok response
            assert_equal "one+two", File.binread(destination)
            assert_equal 2, response.result[:inputs]
          end
        end
      end
    end
  end

  # Analysis returns metadata and no bytes at all.
  def test_no_outputs
    TestCell.boot do |cell|
      with_file("measure me") do |source|
        response = cell.call "test.measure", inputs: [ source ], payload: { asked_for: "bytes" }

        assert_ok response
        assert_equal 10, response.result[:bytes]
        assert_equal "bytes", response.result[:asked_for]
      end
    end
  end

  # Rendering an initials avatar has no input file at all.
  def test_no_inputs_and_no_outputs
    TestCell.boot do |cell|
      response = cell.call "test.echo", payload: { initials: "MD", size: 128 }

      assert_ok response
      assert_equal({ initials: "MD", size: 128 }, response.result[:echoed])
    end
  end

  def test_a_nested_payload_arrives_with_symbol_keys_at_every_depth
    TestCell.boot do |cell|
      payload = { format: "png", operations: { resize_to_limit: [ 800, 600 ] } }

      assert_equal payload, assert_ok(cell.call("test.echo", payload: payload)).result[:echoed]
    end
  end

  def test_an_operation_that_reads_the_descriptor_rather_than_a_copy
    TestCell.boot do |cell|
      with_files("abcdef") do |source, destination|
        response = cell.call "test.reverse", inputs: [ source ], outputs: [ destination ]

        assert_ok response
        assert_equal "fedcba", File.binread(destination)
        assert response.result[:staged], "expected the input not to have been copied onto scratch"
      end
    end
  end

  def test_an_unknown_operation
    TestCell.boot do |cell|
      failure = assert_failed "unsupported", cell.call("test.nonexistent")

      assert_predicate failure, :terminal?
      assert_match "test.nonexistent", failure.message
    end
  end

  # During a rolling deploy the app moves before the accessory reboots, so this arrives at one hundred
  # percent and heals by itself. It must never be recorded against a blob.
  def test_a_version_mismatch_is_transient
    TestCell.boot do |cell|
      failure = assert_failed "protocol", cell.call("test.echo", version: 99)

      refute_predicate failure, :terminal?
    end
  end

  def test_an_operation_that_raises
    TestCell.boot do |cell|
      failure = assert_failed "failed", cell.call("test.broken")

      assert_predicate failure, :terminal?
      assert_equal "RuntimeError", failure.error_class
      assert_match "the operation itself is broken", failure.message
    end
  end

  def test_an_input_that_cannot_be_decoded
    TestCell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("test.undecodable")

      assert_predicate failure, :terminal?
      assert_equal "HotCell::UnreadableInput", failure.error_class
    end
  end

  def test_a_library_exception_an_operation_declared_as_unreadable
    TestCell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("test.declared_unreadable")

      assert_equal "Fixtures::LibraryError", failure.error_class
    end
  end

  # Memory belongs with the resource verdicts rather than in `failed`, because it is the
  # decompression-bomb case and a caller must be able to act on it without parsing a message.
  def test_running_out_of_memory_is_killed_rather_than_failed
    TestCell.boot do |cell|
      failure = assert_failed "killed", cell.call("test.hungry"), limit: "memory"

      assert_predicate failure, :terminal?
    end
  end

  def test_a_result_that_is_not_an_object
    TestCell.boot do |cell|
      assert_match "result is a String", assert_failed("failed", cell.call("test.bad_result")).message
    end
  end

  def test_a_result_json_cannot_carry
    TestCell.boot do |cell|
      assert_match "Symbol", assert_failed("failed", cell.call("test.unserializable_result")).message
    end
  end

  # The worker flushes before reporting success, so this should not happen — which is exactly why it must
  # be handled rather than assumed away. A full tmpfs arrives this way too, so the client classifies zero
  # bytes as transient rather than recording the document as unprocessable.
  def test_an_operation_that_writes_nothing_still_reports_ok_and_leaves_the_output_empty
    TestCell.boot do |cell|
      with_files do |source, destination|
        assert_ok cell.call("test.silent", inputs: [ source ], outputs: [ destination ])

        assert_equal 0, File.size(destination)
      end
    end
  end

  def test_a_descriptor_count_that_does_not_match_the_request
    TestCell.boot do |cell|
      with_file("source") do |source|
        File.open(source, "rb") do |io|
          failure = assert_failed "invalid", cell.dispatch("test.uppercase", descriptors: [ io ],
                                                            inputs: 1, outputs: 1)

          assert_match "wants 2 descriptors and 1 arrived", failure.message
        end
      end
    end
  end

  # Invariant 4, from the side that matters. A cell cannot narrow an access mode, so it declines. The
  # client checks too, and this bypasses that check on purpose.
  def test_a_read_write_descriptor_offered_as_an_input_is_refused_by_the_cell
    TestCell.boot do |cell|
      with_files do |source, destination|
        File.open(source, "r+b") do |readwrite|
          File.open(destination, "wb") do |writable|
            failure = assert_failed "invalid", cell.dispatch("test.uppercase",
                                                             descriptors: [ readwrite, writable ],
                                                             inputs: 1, outputs: 1)

            assert_match "read-only", failure.message
          end
        end
      end
    end
  end

  def test_a_read_only_descriptor_offered_as_an_output_is_refused_by_the_cell
    TestCell.boot do |cell|
      with_files do |source, destination|
        File.open(source, "rb") do |readable|
          File.open(destination, "rb") do |also_readable|
            failure = assert_failed "invalid", cell.dispatch("test.uppercase",
                                                             descriptors: [ readable, also_readable ],
                                                             inputs: 1, outputs: 1)

            assert_match "write-only", failure.message
          end
        end
      end
    end
  end

  def test_a_request_that_is_not_valid_json
    TestCell.boot do |cell|
      assert_failed "invalid", cell.send_line("this is not json\n")
    end
  end

  def test_scratch_is_gone_once_the_request_is_answered
    TestCell.boot do |cell|
      with_files do |source, destination|
        assert_ok cell.call("test.uppercase", inputs: [ source ], outputs: [ destination ])

        refute_path_exists File.join(cell.workspace, "0", "scratch")
      end
    end
  end

  def test_a_worker_runs_in_its_slot_with_its_own_home
    TestCell.boot do |cell|
      result = assert_ok(cell.call("test.whoami")).result

      assert_equal File.join(cell.workspace, "0", "home"), result[:home]
      assert_path_exists result[:home]
    end
  end

  def test_the_cell_logs_a_line_for_every_request
    TestCell.boot do |cell|
      assert_ok cell.call("test.echo")
      assert_failed "failed", cell.call("test.broken")
      cell.stop

      codes = cell.log_events("request").map { |line| line[:code] }
      assert_equal [ "ok", "failed" ], codes
    end
  end
end
