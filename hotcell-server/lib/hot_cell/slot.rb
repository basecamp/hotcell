# frozen_string_literal: true

require "fileutils"
require "securerandom"

module HotCell
  # Slots are a consequence of the concurrency limit rather than something to configure. At most
  # `concurrency` workers run, so number them and hand each worker its number at fork. There is no
  # leasing: a slot is always free when a worker starts, because the thing that bounds workers is the same
  # thing that counts slots. A request never waits for a slot, it waits in the cell's queue.
  #
  # **A slot has one directory per request and it is that request's `$HOME`.** It is created when the
  # request starts and removed when the request ends, so nothing a tool writes under `$HOME` reaches the
  # next request on this slot. The name is stable and the directory behind it is not, which is why a
  # reused worker reports the same path twice.
  #
  # This directory used to survive, to give a tool with an expensive per-user profile a warm one. That is
  # withdrawn. What a tool reads from `$HOME` is configuration, and for the toolchains a cell carries
  # configuration is executable: ImageMagick runs the command lines in `delegates.xml` and applies the
  # rights in `policy.xml`, both read from `$HOME/.config/ImageMagick`. A surviving home therefore let an
  # input that achieved code execution reconfigure every later request on the slot, which is the bound
  # `max_requests_per_worker: 1` is supposed to hold. adr/0003 records the reversal and adr/0002 the
  # reasoning it supersedes.
  #
  # There is one directory and not two. A request's staged inputs and outputs are named inside `$HOME`
  # rather than in a scratch directory of their own, because the two had the same lifetime and the same
  # owner once the home stopped surviving. Staging used to create its directory on demand, which is what
  # kept a descriptor-only operation from paying for one; `$HOME` has to exist for every request either
  # way, so that laziness bought nothing and is gone with it.
  #
  # The filesystem behaviour belongs here rather than in the two processes that call it. The directory is
  # removed from both — the worker before it answers, the supervisor at finish and at reap — so the guard
  # and the swallowed SystemCallError are a rule that has to hold on both sides of a fork, and it had a
  # copy on each.
  Slot = Struct.new(:number, :home) do
    def self.build(workspace, number)
      new number, File.join(workspace, number.to_s, "home")
    end

    def make_home
      FileUtils.mkdir_p home, mode: 0o700
      home
    end

    # A slot whose home is already gone, or which another process removed between the check and the
    # unlink, is the outcome this wants either way.
    def remove_home
      FileUtils.remove_entry home if Dir.exist?(home)
    rescue SystemCallError
      nil
    end

    # **The supervisor renames rather than deletes, and that is a scheduling decision.**
    #
    # How long a recursive delete takes is chosen by the operation that filled the directory. Nothing bounds
    # the number of entries — RLIMIT_FSIZE caps one file, not a million tiny ones — so an input that makes a
    # tool write an enormous tree and then hang buys a deletion the supervisor performs synchronously,
    # after the kill, inside the loop enforcing every other request's deadline.
    #
    # A rename within one filesystem is O(1) and takes the tree out of the way. A worker sweeps it later,
    # after it has answered and before it reports itself idle — see Worker#serve, which is the one window
    # where the unlinking costs nobody's latency.
    #
    # The destination carries a random suffix rather than a counter, because the tool that filled the
    # directory runs as this user and can write to the slot's workspace. A predictable name lets it
    # pre-create a colliding entry, fail the rename, and send the supervisor into the recursive delete the
    # rename exists to avoid. On any rename failure the tree is left where it is, for a later worker's own
    # cleanup to remove off the hot path. The supervisor never deletes a tree inline, whatever goes wrong.
    def discard_home
      return unless Dir.exist?(home)

      File.rename home, "#{home}.discarded-#{Process.pid}-#{SecureRandom.hex(8)}"
    rescue SystemCallError
      nil
    end

    # Nothing here is created at boot, because nothing survives a request. This only clears what an earlier
    # boot left behind.
    def prepare
      remove_home
      sweep
    end

    # Unlinks whatever discard_home renamed out of the way. Partial progress is fine: a sweep killed
    # part-way leaves fewer entries for the next one, so this converges rather than repeating.
    def sweep
      Dir.glob("#{home}.discarded-*").each { |path| FileUtils.remove_entry path }
    rescue SystemCallError
      nil
    end
  end
end
