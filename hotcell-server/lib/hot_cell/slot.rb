# frozen_string_literal: true

require "fileutils"

module HotCell
  # Slots are a consequence of the concurrency limit rather than something to configure. At most
  # `concurrency` workers run, so number them and hand each worker its number at fork. There is no
  # leasing: a slot is always free when a worker starts, because the thing that bounds workers is the same
  # thing that counts slots. A request never waits for a slot, it waits in the cell's queue.
  #
  # The home is reused between requests on purpose. Some converters cannot share one — LibreOffice keeps a
  # profile under $HOME and corrupts itself when two instances share it — and because a per-slot home
  # survives, that expensive profile is created once and is warm afterwards. This is the pre-warming
  # benefit without a warming pass and without the supervisor spawning anything.
  #
  # It is also the one place in this design where two requests are not fully isolated from each other: one
  # can leave a file the next reads. What bounds it is that nothing sensitive belongs in a converter's
  # home, and that scratch is separate and per-request. The danger is what an earlier request wrote into
  # the home rather than what a later one reads out of it — for LibreOffice the user layer composes last,
  # so a write there can disable the converter's own hardening for every later request on that slot.
  #
  # The filesystem behaviour belongs here rather than in the two processes that call it. Scratch is removed
  # from both — the worker before it answers, the supervisor at finish and at reap — so the guard and the
  # swallowed SystemCallError are a rule that has to hold on both sides of a fork, and it had a copy on each.
  Slot = Struct.new(:number, :home, :scratch) do
    def self.build(workspace, number)
      new number, File.join(workspace, number.to_s, "home"), File.join(workspace, number.to_s, "scratch")
    end

    def make_scratch
      FileUtils.mkdir_p scratch, mode: 0o700
      scratch
    end

    # A slot whose scratch is already gone, or which another process removed between the check and the
    # unlink, is the outcome this wants either way.
    def remove_scratch
      FileUtils.remove_entry scratch if Dir.exist?(scratch)
    rescue SystemCallError
      nil
    end

    # **The supervisor renames rather than deletes, and that is a scheduling decision.**
    #
    # How long a recursive delete takes is chosen by the operation that filled the directory. Nothing bounds
    # the number of entries — RLIMIT_FSIZE caps one file, not a million tiny ones — so an input that makes a
    # converter write an enormous tree and then hang buys a deletion the supervisor performs synchronously,
    # after the kill, inside the loop enforcing every other request's deadline.
    #
    # A rename within one filesystem is O(1) and takes the tree out of the way. A worker sweeps it later,
    # after it has answered and before it reports itself idle — see Worker#serve, which is the one window
    # where the unlinking costs nobody's latency.
    def discard_scratch
      return unless Dir.exist?(scratch)

      File.rename scratch, "#{scratch}.discarded-#{Process.pid}-#{(@discarded = @discarded.to_i + 1)}"
    rescue SystemCallError
      remove_scratch
    end

    # The home survives between requests on purpose, so it is created once; scratch must not, so anything
    # a previous boot left behind goes now.
    def prepare
      FileUtils.mkdir_p home, mode: 0o700
      remove_scratch
      sweep
    end

    # Unlinks whatever discard_scratch renamed out of the way. Partial progress is fine: a sweep killed
    # part-way leaves fewer entries for the next one, so this converges rather than repeating.
    def sweep
      Dir.glob("#{scratch}.discarded-*").each { |path| FileUtils.remove_entry path }
    rescue SystemCallError
      nil
    end
  end
end
