# frozen_string_literal: true

require "fileutils"

module HotCell
  # What the cell does to trees it owns and did not write: a request's home after the request, the slot
  # directory at boot, the scratch at boot.
  module Filesystem
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
    # `Dir.exist?` is not the guard, because it follows symlinks and answers false for a dangling one, and
    # an entry a tool left in a directory's place is exactly what this has to remove.
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
    private_class_method :repair_and_remove
  end
end
