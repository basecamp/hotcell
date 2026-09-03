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

        [ :queued_ms, :operation_ms, :writeback_ms, :perform_ms ].each do |key|
          assert timing.key?(key), "expected #{key} in #{timing.inspect}"
        end
        assert_operator timing[:perform_ms], :>=, timing[:operation_ms]
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
        refute response.result[:copied], "expected the input not to have been copied onto scratch"
      end
    end
  end

  # Transient, and the design document says otherwise. An accessory is not updated by a deploy, so an
  # application that ships a client for a new operation before anybody reboots the cell gets this at one
  # hundred percent until they do — and recording that as permanent condemns every blob uploaded during the
  # window. A caller's typo shows up in the `unsupported` rate and in the refusal, which names the operation.
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

  # The payload arrives as keyword arguments, so a key the operation did not declare raises inside
  # perform. Transient, like every unclassified raise: a caller bug must never become a verdict.
  def test_a_payload_key_the_operation_does_not_declare_answers_failed
    TestCell.boot do |cell|
      failure = assert_failed "failed", cell.call("test.blocking", payload: { hours: 1 })

      refute_predicate failure, :permanent?
      assert_equal "ArgumentError", failure.error_class
      assert_match "keyword", failure.message
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

  # A refusal reports only the phases that finished before it, so a verdict says where the request got to
  # rather than only that it failed. The operation never finished here, and posting never started.
  def test_a_refusal_reports_only_the_phases_that_completed
    TestCell.boot do |cell|
      with_files do |source, destination|
        response = cell.call "test.declared_unreadable", inputs: [ source ], outputs: [ destination ]
        assert_failed "unreadable", response

        refute response.timing.key?(:operation_ms), "the operation never finished, so it must not be reported"
        refute response.timing.key?(:writeback_ms), "posting never started, so it must not be reported"
        assert response.timing.key?(:perform_ms), "expected perform_ms in #{response.timing.inspect}"
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

  # A spawn that fails with ENOMEM is the host out of memory, not the input being a bomb, so it must be
  # transient. Recording it as permanent memory would condemn a blob for the cell's own bad moment, the way
  # ENOSPC or EMFILE would if they were not already transient.
  def test_a_spawn_starved_of_memory_is_transient_rather_than_a_memory_verdict
    TestCell.boot do |cell|
      failure = assert_failed "failed", cell.call("test.starved_spawn")

      refute_predicate failure, :permanent?
    end
  end

  # A worker puts every tool it spawns in its own process group, so the supervisor can sweep the group when
  # the worker is gone. A tool that outlived its worker would run with nothing watching it and no deadline,
  # holding CPU and memory until the cgroup ended the cell.
  def test_a_spawned_process_does_not_outlive_its_worker
    spawned = nil

    TestCell.boot do |cell|
      spawned = assert_ok(cell.call("test.orphaner")).result.fetch(:spawned)

      wait_until(what: "the orphaned process to be swept") { !process_running?(spawned) }
    end
  ensure
    begin
      Process.kill :KILL, spawned if spawned
    rescue SystemCallError
      nil
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

  # A worker that exits with a dispatch queued unread on its control socket resets it, and the
  # supervisor's read raised Errno::ECONNRESET through the run loop — one dead worker ended the cell
  # and every in-flight request with it. A reset says what end of stream says: the worker is gone. The
  # reap answers the request it was holding, and the verdict is transient.
  def test_a_worker_that_exits_with_a_dispatch_queued_does_not_take_the_cell_down
    with_file do |pid_path|
      TestCell.boot(deadline: 30, concurrency: 1, max_requests_per_worker: 3) do |cell|
        hijacked = cell.connect

        begin
          hijacked.send_message request_line("test.early_idle", pid_path: pid_path, exit_after: 2)
          wait_until(what: "the worker to report idle early") { File.size?(pid_path) }

          failure = assert_failed "killed", cell.call("test.echo", timeout: 10), cause: "crashed"

          refute_predicate failure, :permanent?
          assert_ok cell.call("test.echo")
        ensure
          hijacked.close
        end
      end
    end
  end

  # An early idle report is believed — the supervisor cannot see that the worker is still running — and
  # `finish` clears what `overdue?` reads, so the worker had no deadline left and nothing ever killed
  # it: it held its slot until it exited on its own. Retirement is the bound instead: a retired worker's
  # next act is exiting, so one still running after the grace is killed, group and all.
  def test_a_retired_worker_that_never_exits_is_killed_after_the_grace
    worker = nil

    with_file do |pid_path|
      TestCell.boot(deadline: 30, concurrency: 1) do |cell|
        lingerer = cell.connect

        begin
          lingerer.send_message request_line("test.early_idle", pid_path: pid_path)
          wait_until(what: "the worker to report idle early") { File.size?(pid_path) }
          worker = Integer(File.read(pid_path))

          wait_until(what: "the lingering worker to be killed") { cell.log_events("worker.lingered").any? }
          wait_until(what: "the killed worker to be gone") { !process_running?(worker) }

          assert_ok cell.call("test.echo")
        ensure
          lingerer.close
        end
      end
    end
  ensure
    begin
      Process.kill :KILL, worker if worker
    rescue SystemCallError
      nil
    end
  end

  # `stopped?` waits for `@children.empty?`, so one worker that reported idle and kept running held a
  # stopping cell open forever: retiring it closed its control socket, and nothing enforced what that
  # means. A rolling deploy would stall until the runtime force-killed the container.
  def test_a_stopping_cell_does_not_wait_forever_for_a_worker_that_reported_idle_and_kept_running
    worker = nil

    with_file do |pid_path|
      TestCell.boot(deadline: 30, concurrency: 1, max_requests_per_worker: 3) do |cell|
        lingerer = cell.connect

        begin
          lingerer.send_message request_line("test.early_idle", pid_path: pid_path)
          wait_until(what: "the worker to report idle early") { File.size?(pid_path) }
          worker = Integer(File.read(pid_path))

          cell.stop

          assert_equal 1, cell.log_events("cell.stopped").size, "the cell never finished stopping"
          refute process_running?(worker), "the lingering worker outlived the cell"
        ensure
          lingerer.close
        end
      end
    end
  ensure
    begin
      Process.kill :KILL, worker if worker
    rescue SystemCallError
      nil
    end
  end

  # The supervisor renames rather than deletes, because how long a recursive delete takes is chosen by
  # whatever filled the directory — and it would run inside the loop enforcing every other deadline. The
  # unlinking lands on the next worker for this slot, which has a deadline of its own.
  def test_a_killed_workers_files_are_taken_out_of_the_way_rather_than_deleted_in_the_loop
    slot = HotCell::Slot.build(Dir.mktmpdir("hotcell-slot"), 0)
    home = slot.make_home
    FileUtils.mkdir_p File.join(home, "deep")

    slot.discard_home

    refute Dir.exist?(home), "the directory should have been renamed away"
    discarded = File.join(slot.directory, "discarded-*")

    assert_equal 1, Dir.glob(discarded).size, "the tree is still there, out of the way"

    slot.sweep

    assert_empty Dir.glob(discarded), "a worker sweeps it once nobody is waiting"
  end

  # **`codes.rb` already states the rule this breaks.** A signal says how a worker died and never why, and
  # workers share a uid, so one can signal another — which the supervisor then read as the victim's own
  # memory exhaustion and wrote against the victim's unrelated input, permanently. Nothing the attacker does
  # here touches that input.
  def test_a_sibling_signal_is_not_a_verdict_on_the_victims_input
    TestCell.boot(concurrency: 2, queue_size: 4) do |cell|
      victim = Thread.new { cell.call("test.blocking", payload: { seconds: 3 }, timeout: 30) }
      sleep 0.3

      assert_ok cell.call("test.signals_sibling", payload: { signal: "ABRT" })

      failure = assert_failed "killed", victim.value

      refute_predicate failure, :permanent?, "a sibling's signal condemned the victim's input"
      assert_equal "crashed", failure.cause, "an unexplained signal was read as a cause"
    end
  end

  # The same forgery with the one signal that has a real meaning. `XFSZ` is what the kernel raises when a
  # write passes RLIMIT_FSIZE, and that verdict is permanent — but a sibling sends it just as easily and a
  # wait status cannot tell the two apart. Catching it in the worker answers both halves at once: the
  # kernel's XFSZ comes back as EFBIG from the write that caused it, and a sibling's does not reach the
  # victim's request at all, because nothing is listening for it.
  def test_a_sibling_can_not_forge_a_file_size_verdict
    TestCell.boot(concurrency: 2, queue_size: 4) do |cell|
      victim = Thread.new { cell.call("test.blocking", payload: { seconds: 3 }, timeout: 30) }
      sleep 0.3

      assert_ok cell.call("test.signals_sibling", payload: { signal: "XFSZ" })

      assert_ok victim.value
    end
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

  def test_staged_files_are_gone_once_the_request_is_answered
    TestCell.boot do |cell|
      with_files do |source, destination|
        assert_ok cell.call("test.uppercase", inputs: [ source ], outputs: [ destination ])

        assert_empty Dir.glob(File.join(cell.workspace, "0", "home-*")),
                     "the request's home is still on the tmpfs after the answer"
      end
    end
  end

  def test_a_worker_runs_in_its_slot_with_its_own_home
    TestCell.boot do |cell|
      result = assert_ok(cell.call("test.whoami")).result

      assert_equal File.join(cell.workspace, "0"), File.dirname(result[:home])
      assert_match(/\Ahome-[0-9a-f]{16}\z/, File.basename(result[:home]),
                   "a request's home should carry a name no earlier request could have prepared")
    end
  end

  # A tool reads its configuration from $HOME, and for the toolchains a cell carries that configuration is
  # executable: ImageMagick runs the command lines in delegates.xml and applies the rights in policy.xml. A
  # home that outlived its request let one compromised conversion reconfigure every later one on that slot,
  # which is what adr/0003 removes. Reuse and one slot, so both requests land on the same worker: the
  # strictest case, and the one the old warm home made impossible to hold.
  def test_a_requests_home_does_not_outlive_it
    TestCell.boot(max_requests_per_worker: 2, concurrency: 1) do |cell|
      first = assert_ok(cell.call("test.home_marker")).result
      second = assert_ok(cell.call("test.home_marker")).result

      refute first[:found], "the first request found a file in a home that should have been fresh"
      refute second[:found], "the second request read a file the first left in $HOME"
    end
  end

  # The removal is what closes the window where a sibling worker reads this request's staged bytes, and it
  # runs from an ensure where it cannot raise. A tool needs nothing but a mode to block it, and a mode on a
  # tree this uid owns is one the worker puts back rather than gives up on — so the bytes go, and there is
  # nothing to report. `slot.uncleaned` is for a removal that repair could not rescue.
  def test_a_home_a_tool_tried_to_lock_open_is_removed_anyway
    cell = TestCell.boot
    blocked = assert_ok(cell.call("test.unremovable_home")).result[:blocked]

    cell.stop

    refute Dir.exist?(File.dirname(blocked)), "the tree a mode blocked is still on the tmpfs"
    assert_empty cell.log_events("slot.uncleaned"), "a removal that succeeded was reported as a failure"
  ensure
    # Stop the cell first: it is still sweeping, so a directory found by the glob can be gone by the chmod.
    # Then hand write permission back wherever the blocked directory landed, because the supervisor renames
    # a home it could not remove and the suite's own cleanup would otherwise fail exactly as the worker did.
    cell&.stop
    Dir.glob("#{cell.workspace}/**/").each { |path| File.chmod 0o700, path if File.directory?(path) } if cell
    cell&.cleanup
  end

  def test_a_home_is_gone_once_the_request_is_answered
    TestCell.boot do |cell|
      result = assert_ok(cell.call("test.whoami")).result

      refute_path_exists result[:home], "the home outlived the request that owned it"
    end
  end

  # ImageMagick unlinks its pixel cache only on a clean exit, and writes it where `TMPDIR` says — which
  # nothing set, so it landed in the shared `/tmp` beside the workspace, where no reap ever looked. A slot's
  # home is removed when the request ends, however it ends; the environment only has to point there.
  # `TMPDIR` for the test process is the cell's own root, so a worker that inherits it rather than getting
  # its own puts the spill exactly where production did.
  def test_a_tools_temp_files_are_removed_with_the_home_of_a_request_that_answers
    with_cell_spilling_into_its_root do |cell, untouched|
      result = assert_ok(cell.call("test.spills")).result

      assert_equal result[:home], File.dirname(result[:spilled]), "Dir.tmpdir is not the request's home"
      refute_path_exists result[:spilled]
      assert_empty Dir.children(cell.socket_root) - untouched - [ "workspace" ],
                   "the request left something in the scratch root beside the workspace"
    end
  end

  def test_a_tools_temp_files_are_removed_with_the_home_of_a_request_that_is_killed
    with_cell_spilling_into_its_root(deadline: 1) do |cell, untouched|
      assert_failed "killed", cell.call("test.spills", payload: { seconds: 30 }, timeout: 30)
      # The verdict is written before the supervisor discards the home; `worker.reaped` follows the discard.
      refute_empty wait_for_event(cell, "worker.reaped"), "the killed worker was never reaped"

      assert_empty Dir.children(cell.socket_root) - untouched - [ "workspace" ],
                   "the killed worker left something in the scratch root beside the workspace"
      assert_empty Dir.glob(File.join(cell.workspace, "0", "home-*")), "the killed request's home was not taken away"
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

      codes = cell.log_events("request").map { |line| line.dig(:hotcell, :code) }
      assert_equal [ "ok", "failed" ], codes
    end
  end

  private
    # Boots a cell whose workers inherit the cell's root as their `TMPDIR`, and yields what the root holds
    # before any request — the workspace is made by the first one — so a test can assert a request added
    # nothing beside it.
    def with_cell_spilling_into_its_root(**options)
      cell = TestCell.new(concurrency: 1, **options)
      inherited = ENV["TMPDIR"]
      ENV["TMPDIR"] = cell.socket_root
      cell.start
      ENV["TMPDIR"] = inherited

      yield cell, Dir.children(cell.socket_root).sort
    ensure
      ENV["TMPDIR"] = inherited
      cell&.stop
      cell&.cleanup
    end
end
