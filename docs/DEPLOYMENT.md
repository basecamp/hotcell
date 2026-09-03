# Deploying a cell

A cell is a second container beside the application, on the same host, sharing one volume that holds its
UNIX sockets. The README carries the complete Kamal configuration for both halves, under
[Configure and deploy the HotCell container](../README.md#configure-and-deploy-the-hotcell-container).

This document explains that configuration: how the image is built, what every flag and setting does,
how the numbers constrain each other, and one alternative worth knowing about. The examples use Kamal;
any orchestrator that can set the same `docker run` flags will do.

[docs/TUNING.md](TUNING.md) is a companion document. It covers measuring your way to values for your
own workload, where this one covers what the values mean.

<!-- regenerate with `rake toc` -->

<!-- toc -->

- [Building an image](#building-an-image)
  * [Using the installed Dockerfile](#using-the-installed-dockerfile)
  * [Bringing your own container](#bringing-your-own-container)
- [Container settings](#container-settings)
  * [Performance](#performance)
  * [Security](#security)
  * [General](#general)
  * [Bound the OpenMP thread pools](#bound-the-openmp-thread-pools)
  * [Sizing the numbers](#sizing-the-numbers)
- [Cell settings](#cell-settings)
  * [Performance](#performance-1)
  * [Security](#security-1)
  * [Changing a shipped operation's limits](#changing-a-shipped-operations-limits)
  * [Settings that trade one for the other](#settings-that-trade-one-for-the-other)
- [Application settings](#application-settings)
  * [The socket's file mode](#the-sockets-file-mode)
  * [The group both sides share](#the-group-both-sides-share)
- [Making the numbers agree](#making-the-numbers-agree)
- [Where scratch lives](#where-scratch-lives)
  * [Keeping the tmpfs](#keeping-the-tmpfs)
  * [A named volume](#a-named-volume)
  * [A host-mounted filesystem](#a-host-mounted-filesystem)
  * [What changes in the numbers](#what-changes-in-the-numbers)

<!-- tocstop -->

## Building an image

### Using the installed Dockerfile

There is no published base image to derive from. `bin/rails hotcell:install` writes a `hotcell/`
directory into the application holding a complete `Dockerfile`, the cell's `Gemfile`, its
`config.rb`, and an `operations/` directory. That Dockerfile is the whole recipe, and it is yours to
customize. Build it from its own directory:

```
docker build -t your-image:latest hotcell/
```

The README's [Configure and deploy the HotCell
container](../README.md#configure-and-deploy-the-hotcell-container) walks through the mechanical
edits, but here are some additional tips:

**Every gem is inside the blast radius.** Keep the cell's `Gemfile` short. A larger supervisor heap also
costs every request — see "Sizing the numbers".

**Load only the operations your image has tools for.** A cell advertises what it loaded, on `describe`,
and a client checks that inventory at boot to catch a cell that does not carry the operation it wants. An
operation whose tool is missing makes that check pass and fails at the first request instead. So requiring
an operation you did not install a tool for is worse than not requiring it.

**The cell's image must create its own socket mount point**, owned by the cell's user — `/run/hotcell/cell`
and not only `/run/hotcell`. Docker creates a missing last level as root, and the cell then cannot create a
socket in it. The installed Dockerfile does this. The application's image needs nothing at its own mount
point.

**Keep the app's and the cell's lockfiles in step.** They resolve hotcell separately. A skew between the
client the app loads and the server the cell runs answers `protocol` on every request. While either tracks
a branch rather than a released version, assert in a test that both lockfiles name the same revision.


### Bringing your own container

If you prefer to use your own base image to run HotCell, that's fine!

#### Conformance checks

`bin/conformance IMAGE` checks whether an image supports hotcell. It boots the image with the flags
under "Container settings", mounts the example operations over `/hotcell/operations`, and drives a
battery of checks from a second container over a shared volume: descriptor round-trips, each kill
verdict, refusal at capacity, and the isolation flags. It exits non-zero on the first failed check.

It then runs the same battery again against your image booted without one security flag at a time, and
requires each run to fail at that flag's own check. That is what makes the isolation results a test of
the flags rather than a restatement of them: a check that cannot see a flag would pass a cell running
without it. A runtime that force-mounts `noexec` onto every tmpfs — Docker Desktop does — cannot host
the `noexec` negative, and that one run reports `SKIP` with the reason.

```
docker build -t my-cell:test hotcell/
bin/conformance my-cell:test
```

The mount shadows the operations your image carries. What the checks cover is the image's runtime — its
Ruby, its gems, and its socket behaviour — not the work your operations do.

`bin/example-image` builds an image to try it against. CI runs both on every push.

#### Additional requirements

Three things conformance cannot prove for you.

**`kernel.yama.ptrace_scope >= 1` on the host.** No container flag can supply it, and it is what stops one
worker reading another request's memory through `/proc/<pid>/mem`. A cell refuses to boot below it:

```
kernel.yama.ptrace_scope is 0 on this host, so one worker can read another request's memory
through /proc/<pid>/mem. No container flag can set it. Set it to 1 or higher and boot again.
```

A host that does not expose the file at all logs `cell.ptrace_scope_unknown` and boots anyway.

**The security flags it cannot observe.** It reads six from inside the cell: `network: none` (the only
interface is `lo`), `read-only` (the root filesystem is mounted `ro`), the tmpfs `noexec` flag, `cap-drop`
(the bounding capability set is empty), `no-new-privileges`, and the uid. A flag the cell cannot read fails
the check rather than passing it. It does not observe the tmpfs `nosuid` and `nodev` flags, `pids-limit`,
or the resource limits. Those are yours to get right, and "Verifying your accessory" is how.

**Your application's group membership.** Conformance does check the shared group, because it runs the cell
as `10001` against files a different user owns: `example.reopen` proves a cell can open an input by name,
and `example.tamper` proves it can do nothing else with either file. What it cannot reach is the
application's own side — its driver owns the files as root, which needs no membership to set a group. That
one fails as `EPERM` in the application rather than in the cell.

#### Verifying your accessory

`bin/conformance` supplies its own docker flags, so it proves the image works when the flags are right.
It doesn't read your Kamal configuration, and it passes against an image you are about to deploy with
`cap-drop` missing.

To check your accessory before you deploy it, print the command Kamal will run. `kamal config` does not
answer this. It prints merged configuration, not the command, so a `--network` emitted twice does not
appear there at all.

```
bundle exec ruby -rkamal -e '
  config = Kamal::Configuration.create_from(
    config_file: Pathname.new("config/deploy.yml"), destination: "production", version: "check")
  puts Kamal::Commands::Accessory.new(config, name: :images).run.flatten.join(" ")
'
```

Read `--network` off that line. It must appear once, as `--network none`. Two of them is the `options:`
mistake described under "Container settings", and Docker rejects the container at boot with exit
status 125.

To check a deployed cell, read the flags on the running container:

```
docker inspect <container> --format '{{json .HostConfig}}' | jq '{
  NetworkMode, ReadonlyRootfs, CapDrop, SecurityOpt, PidsLimit, Memory, MemorySwap, Tmpfs, Binds
}'
```


## Container settings

These are `docker run` flags. Under Kamal they go in an accessory's `options:`, and Kamal supplies no
value of its own for any of them.

`network` is the one exception, and it is the flag this design depends on most. It is an accessory key of
its own, a sibling of `image:` and `roles:`. Kamal always emits a `--network` of its own, `kamal` by
default. An entry under `options:` adds a second `--network` rather than replacing the first, and Docker
refuses the container:

```
docker: conflicting options: cannot attach both user-defined and non-user-defined network-modes
```

The complete accessory, both halves, is in the README under
[Configure and deploy the HotCell container](../README.md#configure-and-deploy-the-hotcell-container).
Copy it from there. The tables below say what each flag does and how to size it.

Give each cell its own volume. Two accessories sharing one would write `work.sock` over each other.

### Performance

**These have no defaults.** Docker applies no limit to a flag you omit, so a cell without them can take
the whole host. Tune each one to your workload and your hardware. The values below are the worked example
from the README's accessory, not recommendations.

| Flag | Example | Tune it from |
| --- | --- | --- |
| `cpus` | `2` | The share of the host this cell may use. Start the cell's `concurrency` at twice this number, and match the image's `OMP_NUM_THREADS` to it — see "Bound the OpenMP thread pools". |
| `memory` | `2g` | The cgroup limit, counting every worker and the tmpfs. Size it from `concurrency × peak RSS` plus the tmpfs. Keep it above the cell's `memory`. On a disk-backed scratch there is no tmpfs term — see "Where scratch lives". |
| `memory-swap` | `2g` | Set it equal to `memory`. Omit it and Docker allows twice `memory` in swap, so the memory limit no longer holds. |
| `tmpfs` size | `size=512m` | Scratch for all concurrent workers together. It pairs with `file_size × concurrency`. Moving scratch onto disk decouples it from `memory` — see "Where scratch lives". |
| `ulimit: stack` | leave it unset | A container inherits the Docker daemon's value, normally 8MB, and that is where to leave it. Lowering it buys a worker about 24MB more room at 2MB, and nothing at all for an operation that shells out. It costs far more than it buys: a thread that overflows the smaller stack dies on `SIGSEGV`, and the cell reports that as `killed`/`crashed`, which is transient — so the request is retried against a limit that will fail it again for as long as the caller's job keeps trying, and nothing in the verdict points at the setting that caused it. Raise the cell's `memory` instead. It belongs here rather than in `config.rb` because glibc reads it at exec, before `Process.setrlimit` could run. |

### Security

**Use these values.** They are what a cell is for. Omit one and the protection is gone, while the cell
serves requests exactly as before.

| Flag | Recommended | What it does |
| --- | --- | --- |
| `network` | `none` | Removes every network interface. A tool that is persuaded to fetch a URL cannot reach anything. Set it as an accessory key, not under `options:`. |
| `read-only` | `true` | Makes the root filesystem read-only. A cell writes only to `/tmp` and to the socket volume. |
| `tmpfs` flags | `nosuid,nodev,noexec` | `noexec` stops a dropped binary running from `/tmp`, which is where a request's files live. It does not cover the socket volume, and it does not stop `ruby payload.rb`. On a disk-backed scratch Docker sets none of them — see "Where scratch lives". |
| `cap-drop` | `ALL` | Removes every Linux capability. |
| `security-opt` | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | `10001:10001` | Runs the cell with no home directory and no shell. Without user namespace remapping this is a host uid, and it is inside the ordinary range, so pick one your hosts do not give to a person. |
| `pids-limit` | `512` | Bounds the number of processes in the cell. It must clear `concurrency` plus the threads and subprocesses one toolchain starts, so check it when you raise `concurrency`. |

### General

Environment variables. The image sets all of them, so set one only to override it.

| Variable | Default | What it does |
| --- | --- | --- |
| `HOTCELL_DIR` | `/run/hotcell/cell` | Where the cell creates `work.sock` and `control.sock`. The app must use the same directory. |
| `HOTCELL_OPERATIONS` | `/hotcell/operations` | The directory the cell loads at boot, in sorted order. |
| `HOTCELL_CONFIG` | `/hotcell/config.rb` | Loaded before the operations, if the file exists. |
| `HOTCELL_WORKSPACE` | a directory under `Dir.tmpdir` | Where each request's directory is made and removed. On the default accessory this is the tmpfs. Must be absolute. At boot the cell empties `Dir.tmpdir` and the workspace's parent of every entry its uid owns, so rebooting the accessory clears a scratch a killed tool filled; it refuses to boot if either is a symlink or holds `HOTCELL_DIR`. Set `TMPDIR` when running `exe/hotcell` outside a container. |
| `HOTCELL_HEALTH_TIMEOUT` | `5` | Seconds `hotcell-health` waits for an answer before it reports unhealthy. |
| `HOME` | `/tmp` | Bundler needs one, and the cell's user has no home directory. A worker replaces it with a directory made for the request and removed with it. |
| `OMP_NUM_THREADS` | `2` | The OpenMP pool size libvips and ImageMagick use. Match it to `cpus`. See "Bound the OpenMP thread pools". |
| `OMP_THREAD_LIMIT` | `8` | The ceiling on that pool, including a library that raises the count itself. |

### Bound the OpenMP thread pools

**Set `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` in the image.** The installed `Dockerfile` sets both, and
on a large host neither is optional: without them a cell dies there. `hotcell:install` leaves an existing
`Dockerfile` untouched, so add both by hand to a cell installed before this and rebuild its image.

OpenMP sizes its thread pool from the host's core count, and a `cpus:` limit is a CFS quota rather than an
affinity mask, so it does not lower that count — on a 98-core host libvips and ImageMagick ask for 98
threads. Each thread stack is 8MB of private anonymous memory, which the cell's `memory` charges as
`RLIMIT_DATA`: under a 1280MB limit, 96 of those stacks fit and 104 do not. Past that line `pthread_create` returns `EAGAIN`, which libgomp treats as unrecoverable — it writes

```
libgomp: Thread creation failed: Resource temporarily unavailable
```

to stderr and calls `exit(1)`. The worker dies before answering, so the caller gets a transient failure and
the job retries it against a host that fails the same way. This killed 285 Basecamp workers in production
on 2026-08-31 and forced a rollback.

That line reaches a log now: the supervisor captures what a worker writes to fd 2 and attaches its tail to
the `worker.killed` that reports its death, as `hotcell.stderr`, and to the failure the caller receives. See
`docs/LOGS.md`.

**Size `OMP_NUM_THREADS` from the container's `cpus`:** the number follows the allocation, not the example
above. It is a thread count, so round a fractional quota down, and up to 1 below that. `OMP_THREAD_LIMIT` is the backstop against a library that raises the count itself by calling
`omp_set_num_threads`, which is what ImageMagick does for `MAGICK_THREAD_LIMIT`.

**The cell forwards the bound to the tools it execs.** A tool sees the environment its operation wrote for
it rather than the worker's own, which is invariant 9, so the image's variables alone would bound
in-process libvips and nothing else. `Operation#run_tool` and mini_magick both carry the pair from the
cell's environment.

**A deploy to staging or beta cannot catch a regression here.** The failure exists only at production's
core count — which is how it reached production. So the guard is a test:
`hotcell-client/test/install_test.rb` holds the scaffold's variables, and an image you customize needs its
own.

To verify a built image, write a GIF inside it and count `/proc/self/task` during the write. GIF is the
cheapest probe: it is the only common output format that quantizes, and quantization is where the threads
appear. Unbounded, the count tracks the visible cores; bounded, it stays at the limit.

### Sizing the numbers

These numbers are arithmetic against the container flags under "Container settings". Against the
`cpus: 2`, `memory: 2g`, `size=512m` accessory there: `concurrency: 4` because a request spends much of
its life off the CPU, so twice `cpus` is where to start; `file_size: 48MB` because that bounds what one
worker writes; and `memory: 1536MB` because that is the measured working value for `RLIMIT_DATA`.

**Size the cell to its most demanding operation.** An operation's own `limits` are clamped to the cell's,
so the cell's numbers only ever take away. Read the `limits` that each operation you carry declares, and
set the cell above the highest of them. The shipped video previewer asks for `deadline: 120` and
`file_size: 128MB`. A cell configured with the 30 seconds and 48MB above kills every video preview, and
nothing else, which is a hard failure to place.

Some guidelines for reading those numbers:

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

## Cell settings

One call, read at boot. Every value has a default, so set only what you are changing.

```ruby
HotCell.limits concurrency: 4, queue_size: 8, queue_wait: 10, deadline: 30,
               max_requests_per_worker: 1, control_deadline: 5,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2, open_files: 256
```

### Performance

| Setting | Default | What it does |
| --- | --- | --- |
| `concurrency` | `4` | Workers that run at once, and the number of slots. Start at twice `cpus`. See "Settings that trade one for the other". |
| `queue_size` | `8` | Connections that may wait for a worker. When `running + queued` reaches `concurrency + queue_size`, the cell answers `capacity`. Use `0` to refuse instead of queueing. |
| `queue_wait` | `10` | Seconds a queued connection may wait before the cell answers `capacity`. This makes a saturated cell answer with a verdict instead of holding the caller until its own timeout. |
| `control_deadline` | `5` | Seconds a control connection may take to send its request. |
| `max_requests_per_worker` | `1` | Requests one worker serves before the cell discards it. `1` forks per request. `:unlimited` keeps a worker for the life of the cell. See "Settings that trade one for the other". |

### Security

| Setting | Default | What it does |
| --- | --- | --- |
| `deadline` | `60` | Maximum wall-clock seconds for one request. The supervisor kills the worker's process group and answers `killed: deadline`. This is the only bound on a wedged or deliberately slow input. There is no CPU limit; `HotCell::Limits` gives the reason. |
| `memory` | `1536MB` | `RLIMIT_DATA` per worker, and the bound on a decompression bomb. A breach gives `killed: memory`. The floor is 1GiB, and a cell below it does not boot. |
| `file_size` | `64MB` | `RLIMIT_FSIZE` per worker. A breach raises `SIGXFSZ` and gives `killed: fsize`. |
| `open_files` | `256` | `RLIMIT_NOFILE` per worker. |

These four are sized like performance settings and exist as limits on a hostile input.

An operation can declare `limits deadline:, memory:, file_size:, open_files:` of its own. Those values
narrow the limit for that request. They never widen it, because the cell's numbers are the ceiling.

### Changing a shipped operation's limits

An operation's `limits` is a class-level declaration that accumulates: naming one limit changes that one
and keeps the rest. So an operator can give a shipped operation a different budget without editing the
gem, by redeclaring the one number after the operation loads:

```ruby
# hotcell/operations/zz_limits.rb
require "active_storage/hot_cell/server/transformers/image/vips"

ActiveStorage::HotCell::Server::Transformers::Image::Vips.limits file_size: 128 * 1024**2
```

The transformer's `deadline`, `memory` and `open_files` are unchanged. Naming a limit to `nil` withdraws
it, which hands that one back to the cell's number.

Three things about that file.

**Require the operation first.** The class has to exist before it can be redeclared. `config.rb` loads
before any operations file, and operations load in sorted order, so a redeclaration that relies on load
order alone belongs in an operations file that sorts last — hence the `zz_` prefix. The `require` at the
top removes that dependency: with it, the same two lines work from any operations file, or from
`config.rb`. Prefer an operations file anyway, so every declaration about operations lives in one place.

**A subclass works the same way, and copies at the moment it declares.** One that declares
`limits deadline: 5` takes every other value from its parent, so a narrowing subclass writes the number it
narrows and nothing else. It takes them once: `limits` resolves to the first ancestor that declared any,
and once a class has stored its own it stops looking up. So redeclaring the parent afterwards does not
reach a child that has already declared — redeclare the child too. A subclass that never declares follows
its parent live.

**The cell's numbers are still the ceiling.** A redeclaration can only ask; the cell clamps it the way it
clamps the original, so the effective value is the smaller of the two. To receive 128MB the cell's own
`file_size` has to allow at least 128MB. A cell at 64MB gives that redeclaration 64MB — a change, but not
the one asked for.

For reference, the shipped Active Storage operations declare:

| Operation | `deadline` | `memory` | `file_size` | `open_files` |
| --- | --- | --- | --- | --- |
| `transformers.image.vips`, `transformers.image.magick` | 30 | 1280MB | 48MB | 256 |
| `analyzers.image.vips`, `analyzers.image.magick` | 10 | 1024MB | 48MB | 64 |
| `analyzers.media.ffprobe` | 30 | 1024MB | 48MB | 128 |
| `previewers.pdf.mutool`, `previewers.pdf.poppler` | 30 | 1024MB | 48MB | 128 |
| `previewers.video.ffmpeg` | 120 | 1536MB | 128MB | 128 |

The 48MB is arithmetic from the example accessory — four workers, two staged files each, on a 512MB
tmpfs — and not a property of any operation. An operation that reads its input through the descriptor
stages only its output, so it needs half of what that arithmetic assumed.

### Settings that trade one for the other

**`max_requests_per_worker` above `1`** lets one request reach another. A worker holds each of its
requests in the same address space, so an input that runs code can read and change every later request
that worker serves. [ADR 0001](../adr/0001-reuse-workers-across-requests.md) records the measurements and
the trade.

At `:unlimited` it also gives up the deadline. A worker reports itself idle when it finishes, and the
supervisor cannot tell a true report from a false one, so a worker that lies stops being timed. At every
finite setting it is still retired and killed on a grace period; at `:unlimited` it is retired by nothing,
and the cell cannot end it. Prefer a finite number, however large.

**`concurrency`** sets how many requests hold bytes in the cell at once. Files are not isolated between
concurrent workers, so this value is also the width of that exposure.
[docs/DESIGN.md](DESIGN.md) gives the measurements.

## Application settings

Per registered cell. They set how the application responds to what a cell answers.

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]              # unset turns every cell off
HotCell.group = ENV["HOTCELL_GROUP"]            # the cell's gid; unset where both sides are one user

HotCell.register "images",
  timeout: 30,
  permanent: ActiveStorage::PreviewError,
  transient: MyApp::ConversionTemporarilyUnavailable,
  on_contract_skew: ->(error, cell) { Sentry.capture_exception(error) }
```

| Setting | Default | What it does |
| --- | --- | --- |
| `HotCell.root` | — | The parent directory that cell names resolve under. When it is unset, every cell is off and callers run in process. |
| `HotCell.group` | — | The group both sides hold, so a cell can open a caller's file by name. Set it to the cell's gid. Unset is for an installation whose two sides already run as one user, which is how development runs. See "The group both sides share". |
| `dir:` | from `root` | An explicit socket directory for one cell. Give a lambda to make a change of path a configuration change instead of a deploy. |
| `timeout:` | `30` | Seconds this caller waits for an answer to a work request. It must clear the cell's `answer_within`. A positive, finite number: `register` raises `ConfigurationError` on anything else, including `nil`, which stops the boot rather than leaving the wait for a cell to decide. |
| `control_timeout:` | `5` | Seconds this caller waits for `describe` or `metrics`. The supervisor answers both inline, with no fork and no queue, so this is short on purpose and must not be raised toward `timeout`. It is what bounds app boot when a cell accepts connections and never answers, and what lets a health check report a wedged cell instead of waiting out a work timeout. Bounded like `timeout:`, and refused the same way. |
| `permanent:`, `transient:` | the gem's classes | The exception classes the application raises for each side of the split. `transient` must not descend from `permanent`, and the client refuses to start if it does. |
| `on_contract_skew:` | — | Called when a cell answers `protocol`, so a version mismatch is visible to an application that rescues broadly. |

### The socket's file mode

The cell creates both sockets `0660`, owned by its own user and group. A Unix socket needs write
permission to connect, so the shared group in the next section is what lets your application reach a cell
at all. It is not optional.

Without it every call fails with `EACCES` from `connect`, and `HotCell.describe_cells` says so at boot,
before any traffic depends on it.

### The group both sides share

Set `HotCell.group` to the cell's gid, and put the application in that group:

```yaml
# config/deploy.yml — the app
servers:
  web:
    options:
      group-add: 10001
```

**Why it is needed.** Two reasons.

The sockets are `0660` and owned by the cell's user and group, so without the group your application
cannot connect to a cell at all.

And an operation that hands a tool a filename does not copy the input. It re-opens the descriptor as
`/dev/fd/N`. That is a fresh open, and the kernel rechecks it against the **cell's** user rather than the
caller's. The two sides do not share a uid, so a mode `0600` file the application owns gives `EACCES`. An
Active Storage tempfile is exactly that.

Six of the eight shipped Active Storage operations hand a tool a filename. The two `magick` ones do not,
because they stage first.

**What the client does with it.** It puts each descriptor in the group and sets the mode on the way out:
`0640` for an input, `0620` for an output. It does this through the open file rather than a path, so it
names nothing.

**It sets those and does not put them back.** The file you hand over keeps the cell's group and the new
mode after the call returns, so a `0600` file of your own comes back readable by that group. Active
Storage hands over tempfiles and unlinks them, so this is invisible there. If you write your own client,
hand over files you are willing to share with the cell's group, and do not pass one whose permissions
something else depends on.

**What that buys, and what it does not.** A cell may read an input and write an output. It may not write
an input or read an output, and it cannot widen either, because it does not own these files and
`cap-drop ALL` leaves it no capability that overrides a mode. The application must own them and be in the
group, which is what lets it set the group at all.

**Do not share a uid instead.** It is the obvious shortcut and it costs two things. The cell would own the
files, so it could set any mode it liked and the one-way rule would stop holding. And a cell that escaped
its container would land on the application's own user on the host, where it can read the environment of
the application's processes. Keep the uids apart and share only the group.

**How it fails.** Immediately, on every call, with `EACCES` from `connect`. There is no partly working
state to misread as healthy.

**What warns first.** `HotCell.describe_cells` checks two things at boot, and warns rather than raising,
like every other boot check here.

- **Whether this process holds `HotCell.group`.** A missing `group-add` is then visible before any traffic
  depends on it. This check is local and needs no cell, so it reports even when every cell is down.
- **Whether the cell runs in that group.** `describe` reports the groups a cell holds, and the client
  compares them. The number lives in your deploy file and the cell's gid is baked into an image built
  somewhere else, so nothing else would catch a cell image that moved its gid. A cell too old to report
  them says nothing.

Neither check trusts what the cell says. The process answering runs untrusted content, so its description
is read inside a rescue: an answer this client cannot use is logged and ignored, and the cell is treated as
one that answered nothing. What that catches is a misdeployment, not a compromised cell — a cell that has been taken over can answer a perfectly well-formed
description that is simply false, and nothing on this side can tell.

What the rescue covers is what a cell *says*. It does not cover a cell that never answers at boot:
`control_timeout` bounds the answer and not the connection, so a listener that stops accepting until its
backlog fills can hold the connect. That is [#20](https://github.com/basecamp/hotcell/issues/20).

And it covers what raises at boot, not what a value does later. A description is handed back whole, so a
cell can put a string in it that is not valid UTF-8, or a number that parses to an infinity. Neither raises
here. The whole returned description stays untrusted: validate it for whatever you do with it — serializing,
matching, storing or rendering are all places these values raise.

## Making the numbers agree

Nothing checks these three for you.

- The client's `timeout` must be more than the cell's `answer_within`, which is
  `queue_wait + deadline + 1`. Below it, a saturated cell reaches the caller as a transport failure
  instead of as `capacity` or `killed`. The client warns at boot, and `describe` reports the number.
- The cell's `memory` must stay below the container's `memory`. At equal values the cgroup fires first,
  and a cgroup kill is a `SIGKILL` with no diagnostic.
- `file_size × concurrency` must fit scratch. Above it, concurrent workers fill it and requests fail
  with `ENOSPC` instead of with a limit verdict. On the default accessory scratch is the tmpfs, and its
  `size=` is the number to fit.

Three things are fixed and cannot be configured: the one-second grace between the signal to a worker and
the kill of its process group, the absence of an `RLIMIT_CPU`, and the socket file mode.

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
the container, so cleanup stops being the mount's job and becomes `Slot#prepare`'s — it clears stale homes
and discarded trees at boot, which is a weaker guarantee than a mount that cannot survive.

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
