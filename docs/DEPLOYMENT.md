# Deploying a cell

One Kamal accessory per cell.

Use an accessory, not an app role. Kamal hard-codes `--network kamal` for app roles, and only an accessory
can set `network: none`. An accessory can still target `roles: [web, jobs]`, which it must: `SCM_RIGHTS`
works only over `AF_UNIX`, so a cell must run on the caller's host.

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
      pids-limit: 512
      cap-drop: ALL
      security-opt: no-new-privileges:true
      user: 10001:10001
      ulimit: stack=2097152:2097152
```

The app mounts the same volume. It then sets `HOTCELL_ROOT` to the parent directory, or registers the cell
with an explicit `dir:`.

A deploy does not update an accessory. Reboot it explicitly:

```
bin/kamal accessory reboot images -d production
```

## Every knob

A cell is tuned in two places. The **container flags** are the ceiling the kernel applies to the whole
cell. The **cell settings** are what the supervisor applies per worker and per request, inside that
ceiling.

The knobs divide into two kinds:

- **Performance knobs** fit the cell to your workload and your hardware. A wrong value costs throughput or
  latency, and measurement finds it.
- **Security knobs** set what the cell contains. A wrong value removes a protection, and the cell's
  behaviour does not change.

### Performance knobs

| Knob | Where | Default | What it does |
| --- | --- | --- | --- |
| `cpus` | container | `2` | The cell's share of the host. Size `concurrency` from this value. |
| `memory` | container | `2g` | The cgroup limit. It counts every worker and the tmpfs. Size it from `concurrency × peak RSS` plus the tmpfs. Keep it above the cell's `memory`. |
| `memory-swap` | container | `2g` | Set it equal to `memory`, so the memory cap does not extend into swap. |
| `tmpfs` size | container | `512m` | Scratch space. It bounds all concurrent workers together, so it pairs with `file_size × concurrency`. |
| `ulimit: stack` | container | `2097152` | Gives about 140MB of `RLIMIT_DATA` headroom per worker at concurrency 4, because each thread in a tool's pool reserves a stack. This cannot be a cell setting: glibc reads `RLIMIT_STACK` once at process start, so a later `Process.setrlimit` has no effect. |
| `concurrency` | cell | `4` | Workers that run at once, and the number of slots. Size it from `cpus`. See "Knobs that are both". |
| `queue_size` | cell | `8` | Connections that may wait for a worker. When `running + queued` reaches `concurrency + queue_size`, the cell answers `capacity`. Use `0` to refuse instead of queueing. |
| `queue_wait` | cell | `10` | Seconds a queued connection may wait before the cell answers `capacity`. This makes a saturated cell answer with a verdict instead of holding the caller until its own timeout. |
| `control_deadline` | cell | `5` | Seconds a control connection may take to send its request. |
| `max_requests_per_worker` | cell | `1` | Requests one worker serves before the cell discards it. `1` forks per request. `:unlimited` keeps a worker for the life of the cell. See "Knobs that are both". |

### Security knobs

| Knob | Where | Value | What it does |
| --- | --- | --- | --- |
| `network: none` | container | — | Removes all network interfaces. A tool that is persuaded to fetch a URL cannot reach anything. |
| `tmpfs` flags | container | `nosuid,nodev,noexec` | `noexec` prevents execution from scratch, which is where a dropped payload lands. |
| `read-only: true` | container | — | Makes the root filesystem read-only. A cell writes only to `/tmp` and to the socket volume. |
| `cap-drop: ALL` | container | — | Removes every Linux capability. |
| `security-opt` | container | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | container | `10001:10001` | Runs the cell as a high uid outside any host user range, with no home directory and no shell. |
| `pids-limit` | container | `512` | Bounds the number of processes in the cell. It must clear `concurrency` plus the threads and subprocesses one operation's toolchain starts. Check it when you raise `concurrency`. |
| `deadline` | cell | `60` | Maximum wall-clock seconds for one request. The supervisor kills the worker's process group and answers `killed: deadline`. There is no CPU limit; `HotCell::Limits` gives the reason. |
| `memory` | cell | `1536MB` | `RLIMIT_DATA` per worker. A breach gives `killed: memory`. The floor is 1GiB, and a cell below it does not boot. |
| `file_size` | cell | `64MB` | `RLIMIT_FSIZE` per worker. A breach raises `SIGXFSZ` and gives `killed: fsize`. |
| `open_files` | cell | `256` | `RLIMIT_NOFILE` per worker. |

The last four are sized like performance knobs. They are listed here because they are what bounds a
hostile input.

Write the cell settings as one call, read at boot:

```ruby
HotCell.limits concurrency: 4, queue_size: 8, queue_wait: 10, deadline: 30,
               max_requests_per_worker: 1, control_deadline: 5,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2, open_files: 256
```

An operation can declare `limits deadline:, memory:, file_size:, open_files:` of its own. Those values
narrow the limit for that request. They never widen it, because the cell's numbers are the ceiling.

### Knobs that are both

**`max_requests_per_worker` above `1`** lets one request reach another. A worker holds each of its
requests in the same address space, so an input that runs code can read and change every later request
that worker serves. [ADR 0001](../adr/0001-reuse-workers-across-requests.md) records the measurements and
the trade.

**`concurrency`** sets how many requests hold bytes in the cell at once. Files are not isolated between
concurrent workers, so this value is also the width of that exposure. See "What is not isolated".

### Making the numbers agree

Nothing checks these three for you.

- The client's `timeout` must be more than the cell's `answer_within`, which is
  `queue_wait + deadline + 1`. Below it, a saturated cell reaches the caller as a transport failure
  instead of as `capacity` or `killed`. The client warns at boot, and `describe` reports the number.
- The cell's `memory` must stay below the container's `memory`. At equal values the cgroup fires first,
  and a cgroup kill is a `SIGKILL` with no diagnostic.
- `file_size × concurrency` must fit the tmpfs. Above it, concurrent workers fill scratch and requests
  fail with `ENOSPC` instead of with a limit verdict.

### Environment

The image sets all of these. Set one only to override it.

| Variable | Default | What it does |
| --- | --- | --- |
| `HOTCELL_DIR` | `/run/hotcell/cell` | Where the cell creates `work.sock` and `control.sock`. The app must use the same directory. |
| `HOTCELL_OPERATIONS` | `/hotcell/operations` | The directory the cell loads at boot, in sorted order. |
| `HOTCELL_CONFIG` | `/hotcell/config.rb` | Loaded before the operations, if the file exists. |
| `HOTCELL_WORKSPACE` | a directory under `Dir.tmpdir` | Where slot homes and scratch live. On the accessory this is the tmpfs. |
| `HOTCELL_HEALTH_TIMEOUT` | `5` | Seconds `hotcell-health` waits for an answer before it reports unhealthy. |
| `HOME` | `/tmp` | Bundler needs one, and the cell's user has no home directory. A worker replaces it with its slot's home before it serves a request. |

### The application side

These settings are per registered cell. They set how the application responds to what a cell answers.

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]   # unset turns every cell off

HotCell.register "images",
  timeout: 30,
  permanent: ActiveStorage::PreviewError,
  transient: MyApp::ConversionTemporarilyUnavailable,
  on_contract_skew: ->(error, cell) { Sentry.capture_exception(error) }
```

| Setting | Default | What it does |
| --- | --- | --- |
| `HotCell.root` | — | The parent directory that cell names resolve under. When it is unset, every cell is off and callers run in process. |
| `dir:` | from `root` | An explicit socket directory for one cell. Give a lambda to make a change of path a configuration change instead of a deploy. |
| `timeout:` | `30` | Seconds this caller waits for an answer. It must clear the cell's `answer_within`. |
| `permanent:`, `transient:` | the gem's classes | The exception classes the application raises for each side of the split. `transient` must not descend from `permanent`, and the client refuses to start if it does. |
| `on_contract_skew:` | — | Called when a cell answers `protocol`, so a version mismatch is visible to an application that rescues broadly. |

Three things are fixed and cannot be configured: the one-second grace between the signal to a worker and
the kill of its process group, the absence of an `RLIMIT_CPU`, and the socket file mode.

## The volume

Two mistakes both fail the same way, as `EACCES` when the cell creates its socket at boot.

**The mount point must exist in the image, owned by the cell's user.** A new named volume takes its
ownership from the directory it covers. The base image creates `/run/hotcell/cell` and chowns it, not only
`/run/hotcell`. If the image creates only the parent, Docker creates the last level as root, and the cell
cannot create a socket in it.

**A bind mount inherits nothing.** It keeps the host directory's ownership. A bind mount in development
needs the host directory chowned to `10001`, or the container run as the host user. Use named volumes in
production.

## The socket's file mode

The cell creates both sockets `0666`. A Unix socket is a filesystem object, and `connect` needs write
permission on it. The two sides do not share a uid — the cell runs as `10001` and the app runs as whatever
its own image sets — so `0600` gives `EACCES` on the app's first request.

The mount topology is what limits access: the directory is a volume mounted into two containers only.

## Host precondition

`kernel.yama.ptrace_scope >= 1`.

A cell refuses to boot below this value. No container flag can supply it. It is what stops one worker from
reading another request's memory through `/proc/<pid>/mem`.

## What is not isolated

Both of these are bounded by values you set here. [docs/DESIGN.md](DESIGN.md) gives the measurements.

**Files are not isolated between concurrent workers.** Every worker runs as the same uid in one mount
namespace. A worker can list another worker's scratch directory, or reach it through
`/proc/<sibling>/fd/N`, and read that request's bytes. A fix needs `CAP_SETUID` or `CAP_SYS_ADMIN`, and
`cap-drop ALL` removes both. Only requests in flight hold bytes in a cell, so `concurrency` and one
toolchain per cell are what bound the exposure.

**A sibling's environment is readable.** `/proc/<pid>/environ` needs only `PTRACE_MODE_READ`, which Yama
does not restrict. A forked worker's environ is fixed at exec time, so `ENV.delete` changes nothing. Keep
credentials out of a cell's environment, and spawn tools with `unsetenv_others`, which
`HotCell::Operation#run_tool` does.

## Deriving an image

The base image carries Ruby, bundler, and the two server gems. It carries no tool. The toolchain a cell
holds decides its blast radius, so a derived image installs it.

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

Files in `/hotcell/operations` load in sorted order, so a leading file can configure the cell:

```ruby
# operations/00_cell.rb
HotCell.limits concurrency: 4, queue_size: 8, deadline: 30, queue_wait: 10, max_requests_per_worker: 1,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2
```

`bundle install` in a derived image is required. The base image's bundle is unfrozen so that operations
can add gems, and an image that skips this step has a stale lockfile against a read-only root filesystem.

### Sizing the numbers

The numbers above are arithmetic against the container flags. Against the `cpus: 2`, `memory: 2g`,
`size=512m` accessory here: `concurrency: 4` because the work is CPU-bound on two cores; `file_size: 48MB`
because that bounds what one worker writes; and `memory: 1536MB` because that is the measured working
value for `RLIMIT_DATA`.

Three results change how you read those numbers.

**`memory` does not multiply by `concurrency`.** It is an address-space charge on one worker. About 620MB
of it is reserved and never touched, and about 450MB of that is Ruby's own reservation, which
`RLIMIT_DATA` charges in full. Subtract 450MB before you read `memory` as the amount an input may consume.
The cgroup limit is what bounds real memory across the cell.

**An input is charged only when an operation asks for its path.** A descriptor that an operation reads in
place costs no tmpfs and no `file_size`, so a multi-gigabyte upload can be analyzed under a small
`file_size`. An operation that needs a filename copies the input onto scratch first, and the kernel
charges that copy exactly as it charges an output. Size `file_size` from the largest thing your operations
write, and count a staged input as one of them.

**A large supervisor makes every request slower.** A worker's fixed cost is copy-on-write settling, and it
is proportional to the supervisor's resident heap. A `before_fork` that requires more than the cell's own
operations need is paid on every request for the life of the deployment.

## Load testing a configuration

`concurrency`, `queue_size` and `queue_wait` are the values that depend on how the work behaves under
contention. Measure them rather than derive them.

`bin/load IMAGE [SCENARIO] [SECONDS] [THREADS]` runs a cell with the flags above and drives it from a
second container. It reports throughput, the verdict breakdown, and latency split into time queued against
time performing. That split is what separates saturation from slowness: queued time that grows while
perform time stays flat means the cell needs more workers.

Two limits of the script:

- It fixes `cpus`, `memory`, the tmpfs size and `pids-limit` at the values above. Only the cell settings
  vary, through `EXAMPLE_CONCURRENCY`, `EXAMPLE_QUEUE_SIZE`, `EXAMPLE_QUEUE_WAIT`, `EXAMPLE_DEADLINE`,
  `EXAMPLE_MEMORY_MB` and `EXAMPLE_FILE_SIZE_MB`.
- It drives the example operations, not yours. It measures the cell's scheduling, not your toolchain.

A number you rely on must come from hardware like production's. [ADR 0001](../adr/0001-reuse-workers-across-requests.md)
records that a development machine and the deployed image disagree.

## Verifying an image

`bin/conformance IMAGE` checks whether an image supports hotcell. It boots the image with the flags above,
mounts the example operations over `/hotcell/operations`, and drives a battery of checks from a second
container over a shared volume: descriptor round-trips, each kill verdict, refusal at capacity, and the
isolation flags. It exits non-zero on the first failed check.

```
docker build -t my-cell:test hotcell/
bin/conformance my-cell:test
```

The mount shadows the operations your image carries. What the checks cover is the image's runtime — its
Ruby, its gems, its user, and its flags — not the work your operations do.

`bin/example-image` builds an image to try it against. CI runs both on every push.
