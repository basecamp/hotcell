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

  # Transient, and the design document says otherwise. An accessory is not updated by a deploy, so an
  # application that ships a client for a new operation before anybody reboots the cell gets this at one
  # hundred percent until they do — and recording that as permanent condemns every blob uploaded during the
  # window. A caller's typo shows up in the `unsupported` rate and in the client's boot-time warning instead.
  def test_an_unknown_operation_is_a_deploy_window_rather_than_a_verdict_on_the_input
    TestCell.boot do |cell|
      failure = assert_failed "unsupported", cell.call("test.nonexistent")

      refute_predicate failure, :permanent?
      assert_match "test.nonexistent", failure.message
    end
  end

  # During a rolling deploy the app moves before the accessory reboots, so this arrives at one hundred
  # percent and heals by itself. It must never be recorded against a blob.
  def test_a_version_mismatch_is_transient
    TestCell.boot do |cell|
      failure = assert_failed "protocol", cell.call("test.echo", version: 99)

      refute_predicate failure, :permanent?
    end
  end

  # Not permanent, and that is the whole point of `failed`. This one really is the operation's own bug and
  # would fail again — but the rescue that produces this code cannot tell it apart from Errno::ENOSPC out of
  # a full tmpfs, so it must answer for the case where retrying is the recoverable one.
  def test_an_operation_that_raises
    TestCell.boot do |cell|
      failure = assert_failed "failed", cell.call("test.broken")

      refute_predicate failure, :permanent?
      assert_equal "RuntimeError", failure.error_class
      assert_match "the operation itself is broken", failure.message
    end
  end

  def test_an_input_that_cannot_be_decoded
    TestCell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("test.undecodable")

      assert_predicate failure, :permanent?
      assert_equal "HotCell::UnreadableInput", failure.error_class
    end
  end

  def test_a_library_exception_an_operation_declared_as_unreadable
    TestCell.boot do |cell|
      failure = assert_failed "unreadable", cell.call("test.declared_unreadable")

      assert_equal "HotCell::Fixtures::LibraryError", failure.error_class
    end
  end

  # A refusal reports the phases that finished before it, so a verdict says where the request got to rather
  # than only that it failed. Staging completed here and converting did not.
  def test_a_refusal_reports_the_phases_that_completed
    TestCell.boot do |cell|
      with_files do |source, destination|
        response = cell.call "test.declared_unreadable", inputs: [ source ], outputs: [ destination ]
        assert_failed "unreadable", response

        assert response.timing.key?(:staging_ms), "expected staging_ms in #{response.timing.inspect}"
        refute response.timing.key?(:convert_ms), "converting never finished, so it must not be reported"
        assert_operator response.timing[:perform_ms], :>=, response.timing[:staging_ms]
      end
    end
  end

  # Memory belongs with the resource verdicts rather than in `failed`, because it is the
  # decompression-bomb case and a caller must be able to act on it without parsing a message.
  def test_running_out_of_memory_is_killed_rather_than_failed
    TestCell.boot do |cell|
      failure = assert_failed "killed", cell.call("test.hungry"), cause: "memory"

      assert_predicate failure, :permanent?
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

  # The cell says so rather than leaving it to the caller to notice. It used to answer `ok` here and let the
  # client compare the output's size, which cannot see which of several outputs was the empty one. A full
  # tmpfs arrives this way, so it is transient rather than a verdict on the document.
  def test_an_operation_that_writes_nothing_is_refused_rather_than_reported_ok
    TestCell.boot do |cell|
      with_files do |source, destination|
        failure = assert_failed "unavailable", cell.call("test.silent", inputs: [ source ],
                                                                        outputs: [ destination ])

        refute_predicate failure, :permanent?
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

  # JSON.generate refuses a String whose bytes are not valid UTF-8, and it refuses it after the response has
  # already been decided. That used to kill the worker with no answer at all, so the caller read a closed
  # socket and retried something that would fail the same way forever.
  def test_a_result_carrying_bytes_json_cannot_encode_is_reported_rather_than_killing_the_worker
    TestCell.boot do |cell|
      failure = assert_failed "failed", cell.call("test.mojibake")

      assert_match "not valid UTF-8", failure.message
      assert_ok cell.call("test.echo")
    end
  end

  # A worker that dies mid-request without a signal is the cell's fault rather than the input's, and a
  # misconfigured cell does it on every request. Recording that against a blob would condemn everything
  # uploaded during a broken deploy, so it is the one `killed` verdict that is not permanent alongside the
  # deadline.
  def test_a_worker_that_dies_without_answering_is_reported_and_is_not_permanent
    TestCell.boot do |cell|
      failure = assert_failed "killed", cell.call("test.vanishes"), cause: "crashed"

      refute_predicate failure, :permanent?
      assert_nil failure.signal
    end
  end

  def test_the_cell_serves_normally_after_a_worker_vanishes
    TestCell.boot(concurrency: 1) do |cell|
      assert_failed "killed", cell.call("test.vanishes"), cause: "crashed"

      assert_ok cell.call("test.echo")
    end
  end

  # The supervisor renames rather than deletes, because how long a recursive delete takes is chosen by
  # whatever filled the directory — and it would run inside the loop enforcing every other deadline. The
  # unlinking lands on the next worker for this slot, which has a deadline of its own.
  def test_a_killed_workers_scratch_is_taken_out_of_the_way_rather_than_deleted_in_the_loop
    slot = HotCell::Slot.build(Dir.mktmpdir("hotcell-slot"), 0)
    FileUtils.mkdir_p File.join(slot.make_scratch, "deep")

    slot.discard_scratch

    refute Dir.exist?(slot.scratch), "the scratch path is free for the next request"
    assert_equal 1, Dir.glob("#{slot.scratch}.discarded-*").size, "the tree is still there, out of the way"

    slot.sweep

    assert_empty Dir.glob("#{slot.scratch}.discarded-*"), "a worker sweeps it once nobody is waiting"
  end

  # The API takes several outputs and success was inferred from their total size, so writing the first and
  # skipping the second was a positive total and read as `ok`. Transient rather than a verdict: the
  # commonest way to write nothing is a full tmpfs.
  def test_an_output_that_received_nothing_is_not_success
    TestCell.boot do |cell|
      with_files do |source, first|
        with_file do |second|
          failure = assert_failed "unavailable", cell.call("test.half_written", inputs: [ source ],
                                                                                outputs: [ first, second ])

          refute_predicate failure, :permanent?
          assert_match "1 of 2 outputs received no bytes", failure.message
        end
      end
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

  # The whole fast path, thirty times over: fork, dispatch, both of the worker's reports, the response, the
  # reap, and the slot coming back. Anything that leaves a finished worker marked in flight shows up here as a
  # spurious kill once its deadline passes.
  def test_many_fast_requests_are_never_reported_as_deaths
    TestCell.boot(deadline: 2, concurrency: 2) do |cell|
      30.times { assert_ok cell.call("test.echo") }
      cell.stop

      assert_empty cell.log_events("worker.killed")
      assert_equal 30, cell.log_events("request").size
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
