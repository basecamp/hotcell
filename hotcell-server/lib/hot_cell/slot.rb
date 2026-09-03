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
  # next request on this slot.
  #
  # This directory used to survive, to give a tool with an expensive per-user profile a warm one. That is
  # withdrawn. What a tool reads from `$HOME` is configuration, and for the toolchains a cell carries
  # configuration is executable: ImageMagick runs the command lines in `delegates.xml` and applies the
  # rights in `policy.xml`, both read from `$HOME/.config/ImageMagick`. A surviving home therefore let an
  # input that achieved code execution reconfigure every later request on the slot, which is the bound
  # `max_requests_per_worker: 1` is supposed to hold. adr/0003 records the reversal and adr/0002 the
  # reasoning it supersedes.
  #
  # **The name is fresh for every request, and that is what makes the removal above a guarantee rather than
  # an intention.** A stable name only holds while the deletion behind it works, and the tool that filled
  # the directory runs as the user that owns it: `chmod 0500` on a directory it has written makes its own
  # configuration unremovable, and the same mode on the slot directory makes it unrenameable too. Both
  # cleanups answer false and both callers log — and a stable name then handed the next request the tree
  # that had just refused to go. A name no earlier request has held is not a name an earlier request could
  # have prepared, so what a failed cleanup now costs is disk rather than the isolation the cell is for.
  #
  # The mode of the slot directory is reasserted for the same reason. It is the one name here that is
  # predictable, so it is the one an earlier request can lock, and a mode on a directory this uid owns is
  # ours to put back.
  #
  # **This bounds what an earlier request left behind, and not what a live one is doing.** Workers share a
  # uid and `0700` is the owner's own mode, so a concurrent sibling — or a `setsid` descendant of a finished
  # request, which process groups do not contain — can still write into a home the moment it exists. The
  # slot directory itself can be renamed aside and replaced, and `chmod` follows what it finds. Both are the
  # residuals `docs/DESIGN.md` records under worker isolation, and neither is closed here.
  #
  # There is one directory per request and not two. A request's staged inputs and outputs are named inside
  # `$HOME` rather than in a scratch directory of their own, because the two had the same lifetime and the
  # same owner once the home stopped surviving. Staging used to create its directory on demand, which is
  # what kept a descriptor-only operation from paying for one; `$HOME` has to exist for every request
  # either way, so that laziness bought nothing and is gone with it.
  #
  # The filesystem behaviour belongs here rather than in the two processes that call it. The directory is
  # removed from both — the worker before it answers, the supervisor at finish and at reap — so the guard
  # and the swallowed SystemCallError are a rule that has to hold on both sides of a fork, and it had a
  # copy on each.
  Slot = Struct.new(:number, :directory, :home) do
    def self.build(workspace, number)
      new number, File.join(workspace, number.to_s)
    end

    # A name no request has held before, so nothing an earlier one did to the tree it was given reaches this
    # one. The suffix is random rather than a counter for the reason the discarded name's is: the previous
    # request could write to this directory, and a predictable name is one it can pre-create.
    def make_home
      FileUtils.mkdir_p directory, mode: 0o700
      FileUtils.chmod 0o700, directory

      self.home = File.join(directory, "home-#{SecureRandom.hex(8)}")
      Dir.mkdir home, 0o700
      home
    end

    # **Returns whether the directory is gone, and every caller logs when it is not.**
    #
    # A home that was already removed, or that another process removed between the check and the unlink, is
    # the outcome this wants either way, so that answers true. Failing to remove one is a different fact and
    # it used to arrive as the same swallowed nil. This is the call that deletes a request's staged input and
    # output before the caller is told anything, so a failure leaves those bytes on the tmpfs for the life of
    # the container — and a sibling worker can cause one, by creating entries under the tree while
    # remove_entry walks it. Same uid, no defence, and it was silent.
    #
    # It still cannot raise. Worker#serve calls this from an ensure, where a raise would replace the caller's
    # response with a crash, and the supervisor calls discard_home from finish and reap, where nothing above
    # rescues anything and a raise stops the cell with every request it holds.
    def remove_home
      return true if home.nil?
      return false unless remove_tree(home)

      self.home = nil
      true
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
    # directory runs as this user and can write to the slot's directory. A predictable name lets it
    # pre-create a colliding entry, fail the rename, and send the supervisor into the recursive delete the
    # rename exists to avoid. On any rename failure the tree is left where it is, for a later worker's own
    # cleanup to remove off the hot path. The supervisor never deletes a tree inline, whatever goes wrong.
    # It renames what is there rather than the name it is holding, because the supervisor is the caller that
    # matters and it does not know the name. `home` is assigned in the worker after the fork, so the
    # supervisor's copy of the slot is still nil when it discards a killed worker's tree. At most one worker
    # holds a slot at a time, so everything matching `home-*` under it is that worker's and nobody else's.
    def discard_home
      FileUtils.chmod 0o700, directory if Dir.exist?(directory)

      Dir.glob(File.join(directory, "home-*")).each do |path|
        File.rename path, File.join(directory, "discarded-#{Process.pid}-#{SecureRandom.hex(8)}")
      end

      self.home = nil
      true
    rescue SystemCallError
      false
    end

    # Nothing here is created at boot, because nothing survives a request. This only clears what an earlier
    # boot left behind — the whole slot directory, since the names inside it are an earlier boot's and not
    # this one's to reconstruct.
    #
    # `Dir.exist?` is not the guard, because it follows symlinks and answers false for a dangling one. An
    # entry a tool left in the slot's place is exactly what this has to remove, and it used to survive the
    # sweep and raise from every later `make_home`.
    def prepare
      remove_tree directory
    end

    # Unlinks whatever discard_home renamed out of the way. Partial progress is fine: a sweep killed
    # part-way leaves fewer entries for the next one, so this converges rather than repeating.
    def sweep
      Dir.glob(File.join(directory, "discarded-*")).map { |path| remove_tree(path) }.all?
    rescue SystemCallError
      # The glob itself can fail, because the slot directory is a name a tool can replace — a symlink loop
      # in its place answers ELOOP here rather than for any one entry. This runs from the worker's ensure,
      # where a raise would replace the caller's response with a crash.
      false
    end

    # **A mode is the only thing a tool needs to make its own tree unremovable, and a mode on a tree this
    # uid owns is ours to put back.** `chmod 0500` on a directory a conversion wrote is enough to fail the
    # recursive delete underneath it, and the delete failing used to be the end of it: one tree per
    # request stayed on the tmpfs until the container ended. The repair is not a permission the process
    # gains, it is one it never lost.
    #
    # Repair only after a failure, never before, so the common request pays for a walk of its own tree
    # once rather than twice. `force:` on the chmod because a partial repair that removes most of the tree
    # is better than none, and the remove that follows is what reports the outcome either way.
    #
    # A class method because the supervisor's boot sweep of the scratch removes what a request left with
    # the same rule.
    def self.remove_tree(path)
      return true unless File.exist?(path) || File.symlink?(path)

      FileUtils.remove_entry path
      true
    rescue SystemCallError
      repair_and_remove path
    end

    def self.repair_and_remove(path)
      FileUtils.chmod_R 0o700, path, force: true
      FileUtils.remove_entry path
      true
    rescue SystemCallError
      false
    end

    private
      def remove_tree(path)
        Slot.remove_tree path
      end
  end
end
