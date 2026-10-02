# Scratch

## Where scratch lives

The configuration documented above uses RAM-backed tmpfs for scratch space. This couples three
configuration params: an operation's `FSIZE` (max file size write), and the `tmpfs` and `memory`
container configs. Increasing `FSIZE` require increasing the other two, which may end up putting
memory pressure on the host node.

Scratch is `/tmp`: staged inputs, staged outputs, and every intermediate a tool writes. Those pages
are charged to the container's cgroup and, with `memory-swap` equal to `memory`, they cannot be
reclaimed or swapped — so the tmpfs `size=` and the container's `memory` grow together, byte for
byte. Every time `file_size` goes up to admit a larger conversion, `memory` pays for it.

Moving scratch onto disk breaks that coupling. Files written there pass through the page cache, and the
kernel writes those pages back and drops them under pressure, so a large file on scratch can no longer
OOM the cell and `memory` sizes from `concurrency × peak RSS` alone, kept above the cell's own `memory`
rlimit.

Three layouts, trading the same three things:

| Layout | Backed by | Size cap | `nosuid,nodev,noexec` | Provisioning |
| --- | --- | --- | --- | --- |
| tmpfs | RAM, charged to the cgroup | the `size=` option | yes | none |
| named volume | disk, under `/var/lib/docker/volumes` | none | none | none |
| host mount | disk | the filesystem's size | from the host mount | per host |

Both disk layouts give up speed, and that is rarely the bottleneck: on NVMe, for spool-and-process
pipelines, the descriptor design already keeps the biggest bytes off scratch entirely. Both also outlive
the container, so cleanup stops being the mount's job and becomes the cell's. At boot it empties
`TMPDIR` and the workspace's parent of every entry its uid owns, `lost+found` excepted, so rebooting
the accessory clears a scratch a killed tool filled. A removal that fails is logged as `scratch.unswept`
and does not stop the boot. The cell refuses to boot if either directory is missing, is reached through a
symlink its uid owns, or holds `HOTCELL_DIR`.

The rule is the same in every layout, so a cell's `TMPDIR` must be a directory nothing else uses. In the
container `/tmp` is the cell's own; on a developer's machine it is everyone's, so an uncontainerized cell
is booted with `hotcell --development`, which never sweeps the directory it is given. Its scratch is a
directory of its own beneath it, named for `HOTCELL_DIR`. An explicit `HOTCELL_WORKSPACE` has its parent
swept wherever it points, flag or not.

### Keeping the tmpfs

Right when scratch is small and stays small. It is RAM-fast, it vanishes when the container stops, and one
flag carries the size cap and all three security flags. It is the only layout where Docker sets those
flags for you.

### A named volume

The way onto disk that needs nothing of the host. Replace the `tmpfs:` option with a named volume on the
same path:

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

Docker creates the volume on first boot and initializes it from the image's own `/tmp` — the content and
the permissions both, which is `1777` on the Debian base — so the cell's uid can write to it with no host
work at all. No `mkdir`, no `chown`, no fstab line. That is the same rule the socket volume already
depends on, and the installed `Dockerfile` records it.

What you give up is the cap and the flags, and Docker can set neither on a named volume. A runaway write
is then bounded only by the `file_size` rlimit per file and by deadline × disk throughput, and a fill
lands on whatever filesystem holds `/var/lib/docker` — usually the root filesystem. The `isolation`
operation reports `scratch_noexec: false` against a cell configured this way, which is the truth.

### A host-mounted filesystem

The way onto disk that keeps the cap and the flags. Give the accessory an absolute host path, which Kamal
passes to `docker run -v` verbatim as a bind mount:

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

**Give it a dedicated filesystem** — a partition, an LV, or a loopback image file. Its size is then the
cap, so a fill stays inside scratch and reaches the caller as `Errno::ENOSPC`, which the cell classifies
`failed`: transient, retried, never recorded against a blob. The flags ride the host mount options, and a
bind mount carries its source's flags into the container, so `scratch_noexec` still reports true.

A plain host directory is not worth the trouble. It gives up the cap and the flags exactly as a named
volume does, and adds the `chown` work that a named volume avoids.

**Chown the source.** A bind mount keeps the host directory's ownership rather than taking the image's,
and the cell runs as `10001:10001`. Docker creates a missing source owned by root, and the cell then fails
every request with `EACCES`. Create and chown it before the first boot. As a loopback image — no
repartitioning, and sized from `file_size × concurrency` plus headroom:

```
fallocate -l 8G /var/lib/hotcell-scratch.img
mkfs.ext4 /var/lib/hotcell-scratch.img
mkdir -p /var/lib/hotcell-scratch
echo '/var/lib/hotcell-scratch.img /var/lib/hotcell-scratch ext4 loop,nosuid,nodev,noexec 0 0' >> /etc/fstab
mount /var/lib/hotcell-scratch
chown 10001:10001 /var/lib/hotcell-scratch
```

**Do not use the host's `/tmp` as the source.** On most systemd distributions it is itself a tmpfs, which
puts scratch back in RAM — still charged to the cell's cgroup, because the writer pays — and
`systemd-tmpfiles` reaps old files out from under long requests. Check the source before you use it:

```
findmnt -T /var/lib/hotcell-scratch -o TARGET,SOURCE,FSTYPE,OPTIONS
```

`FSTYPE` must be a disk filesystem, and `OPTIONS` shows which of the three flags the cell will actually
get.

### What changes in the numbers

The `file_size × concurrency` arithmetic under "Making the numbers agree" does not disappear. On either
disk layout `memory` loses its tmpfs term, and the number that has to fit becomes the host filesystem's
size — or, on a named volume, nothing, because there is no cap to fit inside.

Mind one interaction. If you also raise or remove `file_size` so that large conversions succeed, a cap is
the only bound left on what a runaway write consumes; without one the bound is deadline × disk throughput.
An uncapped layout with an uncapped `file_size` is the one combination with no bound at all, and a capped
filesystem is what makes a generous `file_size` safe to run.

Two things do not change on any layout:

- `HOTCELL_WORKSPACE` keeps its default. It lives under `Dir.tmpdir`, and the server treats scratch as a
  plain directory without ever checking the filesystem type.
- A full scratch still reaches the caller as `failed`, which is transient, exactly as a full tmpfs did.
