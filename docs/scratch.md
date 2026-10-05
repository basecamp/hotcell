---
type: Reference
title: "Scratch"
order: 7
description: "Where a cell stages files: the tmpfs, named volume, and host-mount layouts, and the boot sweep."
sources:
  - hotcell-server/lib/hot_cell/supervisor.rb
  - hotcell-server/lib/hot_cell/filesystem.rb
  - hotcell-server/lib/hot_cell/slot.rb
  - hotcell-server/lib/hot_cell/sweeper.rb
---

# Scratch

This page describes the cell's scratch, the filesystem where requests stage their files, and the layouts
that you can choose for it: a tmpfs, a named volume, or a host-mounted filesystem.

Scratch is `/tmp`. It holds staged inputs, staged outputs, and every intermediate file that a tool writes.
Each request's directory is under `HOTCELL_WORKSPACE`, which defaults to a directory under `TMPDIR`. See
[Cell settings](cell-settings.md#environment-variables).

## Why the layout matters

The README's accessory puts scratch on a RAM-backed tmpfs. That couples three settings: an operation's
`file_size`, the container's tmpfs `size=`, and the container's `memory`. Raising `file_size` requires
raising the other two, which can put memory pressure on the host.

Pages on the tmpfs are charged to the container's cgroup. With `memory-swap` equal to `memory`, the kernel
can't reclaim or swap them, so the tmpfs `size=` and the container's `memory` grow together, byte for byte.
Every time that `file_size` goes up to admit a larger conversion, `memory` pays for it.

Moving scratch onto disk breaks that coupling. Files written there pass through the page cache, and the
kernel writes those pages back and drops them under pressure. A large file on scratch can then no longer
run the cell out of memory, and `memory` sizes from `concurrency × peak RSS` alone, kept above the cell's
own `memory` limit.

## Layouts

| Layout | Backed by | Size cap | `nosuid,nodev,noexec` | Provisioning |
| --- | --- | --- | --- | --- |
| tmpfs | RAM, charged to the cgroup | the `size=` option | yes | none |
| named volume | disk, under `/var/lib/docker/volumes` | none | none | none |
| host mount | disk | the filesystem's size | from the host mount | each host |

Both disk layouts give up speed, and speed is rarely the bottleneck: on NVMe, for spool-and-process
pipelines, the descriptor design already keeps the largest files off scratch entirely. Both disk layouts
also outlive the container, so cleanup becomes the cell's job rather than the mount's. See
[Boot sweep](#boot-sweep).

### tmpfs

Use a tmpfs when scratch is small and stays small. It's as fast as RAM, it disappears when the container
stops, and one flag carries the size cap and all three security flags. It's the only layout where Docker
sets those flags for you. The README's accessory uses it:

```yaml
tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
```

### Named volume

A named volume moves scratch onto disk and needs nothing on the host. Replace the `tmpfs:` option with a
named volume on the same path:

```yaml
# config/deploy.yml — the cell, changed from the README's accessory
accessories:
  active_storage:
    volumes:
      - hotcell-sockets:/run/hotcell/cell       # unchanged
      - hotcell-scratch:/tmp                    # scratch, on disk

    options:
      memory: 2g                                # no tmpfs term: concurrency × peak RSS
      memory-swap: 2g                           # equal to memory
      # tmpfs: gone. /tmp is the named volume above.
```

Docker creates the volume on first boot and initializes it from the image's own `/tmp`, both the content
and the permissions, which are `1777` on the Debian base. So the cell's uid can write to it with no host
work: no `mkdir`, no `chown`, and no fstab line. The socket volume depends on the same rule, and the
installed `Dockerfile` records it. See [experiment 4](development/experiments.md).

You give up the size cap and the security flags, because Docker can set neither on a named volume. A
runaway write is then bounded only by the `file_size` limit on each file and by deadline × disk
throughput, and a fill lands on whatever filesystem holds `/var/lib/docker`, usually the root filesystem.
The `isolation` operation reports `scratch_noexec: false` against a cell configured this way, which is
true.

### Host-mounted filesystem

A host-mounted filesystem moves scratch onto disk and keeps the size cap and the security flags. Give the
accessory an absolute host path, which Kamal passes to `docker run -v` as a bind mount:

```yaml
# config/deploy.yml — the cell, changed from the README's accessory
accessories:
  active_storage:
    volumes:
      - hotcell-sockets:/run/hotcell/cell       # unchanged
      - /var/lib/hotcell-scratch:/tmp           # scratch, from the host

    options:
      memory: 2g                                # no tmpfs term: concurrency × peak RSS
      memory-swap: 2g                           # equal to memory
      # tmpfs: gone. /tmp is the bind mount above, and its nosuid,nodev,noexec
      #        must come from the host mount.
```

Give it a dedicated filesystem: a partition, a logical volume, or a loopback image file. Its size is then
the cap, so a fill stays inside scratch and reaches the caller as `Errno::ENOSPC`, which the cell
classifies as `failed`: transient, retried, and never recorded against a blob. The security flags come
from the host mount options, and a bind mount carries its source's flags into the container, so
`scratch_noexec` still reports true.

A plain host directory isn't worth it. It gives up the cap and the flags exactly as a named volume does,
and adds the `chown` work that a named volume avoids.

Chown the source. A bind mount keeps the host directory's ownership rather than taking the image's, and
the cell runs as `10001:10001`. Docker creates a missing source owned by root, and the cell then fails
every request with `EACCES`. Create and chown the source before the first boot. For example, as a loopback
image, with no repartitioning, sized from `file_size × concurrency` plus headroom:

```
fallocate -l 8G /var/lib/hotcell-scratch.img
mkfs.ext4 /var/lib/hotcell-scratch.img
mkdir -p /var/lib/hotcell-scratch
echo '/var/lib/hotcell-scratch.img /var/lib/hotcell-scratch ext4 loop,nosuid,nodev,noexec 0 0' >> /etc/fstab
mount /var/lib/hotcell-scratch
chown 10001:10001 /var/lib/hotcell-scratch
```

**Caution:** Don't use the host's `/tmp` as the source. On most systemd distributions, it's itself a
tmpfs, which puts scratch back in RAM, still charged to the cell's cgroup because the writer pays. And
`systemd-tmpfiles` deletes old files out from under long requests.

Check the source before you use it:

```
findmnt -T /var/lib/hotcell-scratch -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`FSTYPE` must be a disk filesystem, and `OPTIONS` shows which of the three flags the cell gets.

## Boot sweep

At boot, the cell empties `TMPDIR` and the workspace's parent of every entry that its uid owns, except
`lost+found`. Rebooting the accessory therefore clears a scratch that a killed tool filled. A removal that
fails is logged as `scratch.unswept` and doesn't stop the boot.

The cell refuses to boot if either directory:

- Is missing.
- Is reached through a symlink that its uid owns.
- Holds `HOTCELL_DIR`.

The rule is the same in every layout, so a cell's `TMPDIR` must be a directory that nothing else uses. In
the container, `/tmp` is the cell's own. On a developer's machine, it's everyone's, so boot an
uncontainerized cell with `hotcell --development`, which never sweeps the directory that it's given. Its
scratch is a directory of its own beneath that directory, named for `HOTCELL_DIR`. An explicit
`HOTCELL_WORKSPACE` has its parent swept wherever it points, with or without the flag. See
[Development mode](cell-settings.md#development-mode).

## What changes in the numbers

The `file_size × concurrency` constraint in [Tuning](tuning.md#constraints-between-the-numbers) applies
to every layout:

- On a tmpfs, the number to fit is the tmpfs `size=`, and `memory` includes the tmpfs.
- On either disk layout, `memory` loses its tmpfs term. On a host mount, the number to fit is the host
  filesystem's size. On a named volume, there's no cap to fit inside.

If you also raise or remove `file_size` so that large conversions succeed, a cap is the only bound left on
what a runaway write consumes. Without a cap, the bound is deadline × disk throughput. An uncapped layout
with an uncapped `file_size` is the one combination with no bound at all, and a capped filesystem is what
makes a generous `file_size` safe to run.

Two things don't change on any layout:

- `HOTCELL_WORKSPACE` keeps its default. It's under `Dir.tmpdir`, and the server treats scratch as a plain
  directory without checking the filesystem type.
- A full scratch still reaches the caller as `failed`, which is transient, as a full tmpfs does.
