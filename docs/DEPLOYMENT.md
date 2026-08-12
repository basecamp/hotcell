# Deploying a cell

One Kamal accessory per cell.

An accessory rather than an app role, because Kamal hard-codes `--network kamal` for app roles and only an
accessory can set `network: none`. An accessory can still target `roles: [web, jobs]` to land on the same
hosts as the app, which it must: `SCM_RIGHTS` works only over `AF_UNIX`, so a cell is always on the caller's
host.

```yaml
accessories:
  images:
    image: registry.37signals.com/basecamp/hotcell-images:latest
    roles: [ web, jobs ]
    volumes:
      - hotcell-images:/run/hotcell/cell
    options:
      network: none
      read-only: true
      tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
      memory: 2g
      memory-swap: 2g
      cpus: 2
      pids-cause: 512
      cap-drop: ALL
      security-opt: no-new-privileges:true
      user: 10001:10001
      ulimit: stack=2097152:2097152
```

The app mounts the same volume and sets `HOTCELL_ROOT` to its parent, or registers the cell with an explicit
`dir:`.

## The flags, and which ones matter most

| Flag | Why |
| --- | --- |
| `network: none` | The strongest property here, and the only one that is binary and auditable: either the container has interfaces or it does not. Under it, a document that persuades a tool to fetch a URL has nowhere to go. |
| `tmpfs … noexec` | The easiest to omit and worth the most. Scratch is exactly where a dropped payload would land. |
| `read-only: true` | Nothing in a cell writes outside `/tmp` and the socket volume. |
| `memory-swap` equal to `memory` | Stops the memory cap leaking into swap. |
| `cap-drop: ALL` | Also the reason two residual exposures cannot be closed — see below. |
| `user: 10001:10001` | High, outside any host user range, created `--no-create-home` with `nologin`. |
| `ulimit: stack` | Worth roughly 140MB of `RLIMIT_DATA` headroom per worker at concurrency 4, because every thread a tool's pool starts reserves a stack. It cannot go in an operation's `limits`: glibc snapshots `RLIMIT_STACK` at process init, so `Process.setrlimit` in a worker changes the reported value and nothing else. |

Accessories are not updated by a deploy. Rebooting one is explicit:

```
bin/kamal accessory reboot images -d production
```

## The volume, and two ways to get it wrong

Both of these cost an afternoon and both fail the same way, as `EACCES` creating a socket at boot.

**The mount point must exist in the image, owned by the cell's user.** A new named volume takes its ownership
from the directory it covers. The base image creates `/run/hotcell/cell` and chowns it, not just
`/run/hotcell` — create only the parent and Docker creates the missing level as root, and the cell cannot
create its own socket in it.

**A bind mount inherits nothing.** It keeps the host directory's ownership, so a bind mount for local
development needs the host directory chowned to `10001`, or the container run as the host user. Named volumes
in production, and expect to do something explicit in development.

## The socket's file mode

The cell creates both sockets `0666`. A Unix socket is a filesystem object and `connect` needs write
permission on it, and the two sides do not share a uid — the cell runs as `10001` and the app runs as
whatever its own image says, so `0600` is a bare `EACCES` at the app's first variant.

What actually contains this is the mount topology: the directory is a volume mounted into exactly two
containers, so "anyone who can see this socket" is already "the app and the cell". A shared supplementary gid
with `0660` is tighter and needs the two images to agree on a number forever, which is a coordination cost for
no threat this design is trying to stop.

## Host precondition

`kernel.yama.ptrace_scope >= 1`.

A cell **refuses to boot** below it. That is the one sysctl no container flag can supply, and it is the only
thing stopping one worker from reading another request's memory through `/proc/<pid>/mem`. It is invisible to
the image and it voids the guarantee silently, so a warning in a log would be a dead control.

## What is not isolated, and cannot be

Stated rather than papered over, because both are bounded by decisions you make here.

**Files are not isolated between concurrent workers.** Every worker runs as the same uid in one mount
namespace, so a worker that lists another worker's scratch — or reaches it through `/proc/<sibling>/fd/N` —
gets that request's bytes. The two fixes that would work need `CAP_SETUID` for a per-worker uid or
`CAP_SYS_ADMIN` for a per-request mount namespace, and `cap-drop ALL` removes both. What bounds it is the size
of the window and the value of the contents: only requests in flight have bytes inside a cell, a cell holds no
credentials, and a cell carries one toolchain. So per-toolchain cells and a sober `concurrency` are containment
decisions and not just scheduling ones.

**A sibling's environment is readable.** `/proc/<pid>/environ` needs only `PTRACE_MODE_READ`, which Yama does
not restrict, and a forked worker's environ is fixed at exec time so `ENV.delete` changes nothing. Two things
replace it: keep anything worth stealing out of a cell's environment, and spawn tools with
`unsetenv_others`, which `HotCell::Operation#run_tool` does. An exec'd child is the one process in this picture
whose environ we actually control.

`hidepid=2` on `/proc` would remove the sysctl dependency by hiding sibling processes entirely. It is not
available: Docker rejects Podman's `--security-opt proc-opts=`, and remounting `/proc` inside the container
needs `CAP_SYS_ADMIN`.

## Deriving an image

The base image carries Ruby, bundler, and the two server gems. It carries no tool, because which
toolchain a cell holds is what decides its blast radius.

```dockerfile
FROM registry.37signals.com/basecamp/hotcell:latest

USER root
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libvips42 imagemagick && \
    rm -rf /var/lib/apt/lists/*
USER hotcell

COPY --chown=hotcell:hotcell operations /hotcell/operations
RUN bundle install
```

Files in `/hotcell/operations` load in sorted order at boot, so a leading one configures the cell:

```ruby
# operations/00_cell.rb
HotCell.limits concurrency: 4, queue_size: 8, deadline: 30, queue_wait: 10, max_requests_per_worker: 1,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2
```

`bundle install` in the derived image is required, not optional. The base image's bundle is deliberately
unfrozen so that operations can bring their own gems, and a derived image that skips it has a stale lockfile
against a read-only root filesystem.

**Sizing those numbers.** They are arithmetic against the flags above, not defaults to copy. Against the
`cpus: 2`, `memory: 2g`, `size=512m` accessory here: `concurrency: 4` because the work is CPU-bound on two
cores; `file_size: 48MB` because that bounds what one worker *writes* — its output plus any scratch a tool
produces — not what it reads, since inputs are read through their descriptors and never staged onto the
tmpfs; and `memory: 1536MB` because that is the measured working value for `RLIMIT_DATA`.

An input is not charged to `file_size` or to the tmpfs at all: it is the caller's own file, read in place
over `/dev/fd`, so a multi-gigabyte upload analyzes or previews under a small `file_size` and a small tmpfs.
Size `file_size` from the largest output an operation writes, not the largest input it accepts.

`memory` does not multiply by `concurrency`, which is the easiest mistake here. It is an address-space charge
on one worker and roughly 620MB of it is reserved and never touched — about 450MB of that is Ruby's own
untouched reservation, which `RLIMIT_DATA` charges in full. The cgroup limit is what bounds real memory across
the cell, and it counts the tmpfs too. Size `memory` from the 1GiB floor and the cgroup from
`concurrency × realistic peak RSS` plus the tmpfs, and keep `memory` strictly below the cgroup limit — equal
values mean the cgroup fires first and you get the bare `SIGKILL` the rlimit existed to avoid.

## Verifying an image

`docker/smoke` boots an image with every flag above and converts one file through it from a second container
over a shared volume. It is the only check in this repository that covers `network: none`, `cap-drop`, the
read-only root filesystem, and the tmpfs flags, and the only one that shows a descriptor crossing between two
containers.

```
docker build -t hotcell:test .
docker/smoke hotcell:test
```
