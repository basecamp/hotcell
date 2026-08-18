# Deploying a cell

A cell is a second container beside the application. Four things have to be true, whatever you deploy
with:

1. **The same host as the caller.** `SCM_RIGHTS` works only over `AF_UNIX`, so a descriptor cannot cross
   machines.
2. **One volume shared by both containers**, holding the cell's sockets. The cell writes them at
   `HOTCELL_DIR`, and the app finds them at `$HOTCELL_ROOT/<cell name>`.
3. **The container flags under "Container settings"**, which are what makes a cell a cell.
4. **`kernel.yama.ptrace_scope >= 1` on the host.** A cell refuses to boot below this, and no container
   flag can supply it — it is what stops one worker reading another request's memory through
   `/proc/<pid>/mem`.

This document is in the order you do it: build the image, set the container flags, agree the three things
both sides share, then the settings, then verify. The examples use Kamal; any orchestrator that can set
the same `docker run` flags will do.

## Building an image

There is no published base image to derive from. `bin/rails hotcell:install` writes a `hotcell/` directory
into the application holding a complete `Dockerfile`, the cell's `Gemfile`, its `config.rb`, and an
`operations/` directory. That Dockerfile is the whole recipe, and it is yours to change. Build it from its
own directory:

```
docker build -t your-image:latest hotcell/
```

Three places to change, and nothing else is required.

**The `Dockerfile`'s apt line.** Install the tools your operations run, and nothing else. The toolchain a
cell carries is what decides its blast radius.

```dockerfile
# hotcell/Dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends libvips42 imagemagick && \
    rm -rf /var/lib/apt/lists/*
```

**The `Gemfile`.** Add the gems your operations need. Keep it short: every gem is inside the blast radius,
and a larger supervisor heap costs every request — see "Sizing the numbers".

**`config.rb`.** The cell settings. It loads before the operations, which then load in sorted order.

```ruby
# hotcell/config.rb
HotCell.limits concurrency: 4, queue_size: 8, queue_wait: 10, deadline: 30,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2
```

Read "Sizing the numbers" before copying those. They are arithmetic against one set of container flags,
and they are below what some shipped operations declare.

Running the installer again leaves every file that already exists untouched, so customizing is safe.

**Load only the operations your image has tools for.** A cell advertises what it loaded, on `describe`, and
a client checks that inventory at boot to catch a cell that does not carry the operation it wants. An
operation whose tool is missing makes that check pass and fails at the first request instead. A gem that
ships several toolchains loads them all through its entry point, so require the files you want:

```ruby
# hotcell/operations/active_storage.rb
require "active_storage/hot_cell/server/transformers/image/vips"
require "active_storage/hot_cell/server/analyzers/image/vips"
require "active_storage/hot_cell/server/previewers/pdf/mutool"
```

**Keep the app's and the cell's lockfiles in step.** They resolve hotcell separately. A skew between the
client the app loads and the server the cell runs answers `protocol` on every request. While either tracks
a branch rather than a released version, assert in a test that both lockfiles name the same revision.

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

Three more results change how you read those numbers.

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

## If you deploy with Kamal

Use one accessory per cell, not an app role. Kamal hard-codes `--network kamal` for app roles, and only an
accessory can set `network: none`. An accessory can still target `roles: [web, jobs]`, which it must, to
land on the caller's hosts.

A deploy does not update an accessory. Reboot one explicitly:

```
bin/kamal accessory reboot images -d production
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

An illustrative Kamal configuration, the cell's half:

```yaml
# config/deploy.yml — the cell
accessories:
  images:                                       # the cell's name; the app registers it under this
    image: your.registry.com/your-image:latest
    roles: [ web, jobs ]                        # a cell runs on its caller's host
    network: none                               # an accessory key, never an option — see above
    volumes:
      - hotcell-sockets:/run/hotcell/cell       # the sockets the app talks to this cell through
    options:
      # Performance. No defaults — tune each one. See "Performance" below.
      cpus: 2
      memory: 2g
      memory-swap: 2g                           # equal to memory

      # Security. Use these values. See "Security" below.
      read-only: true
      cap-drop: ALL
      security-opt: no-new-privileges:true
      user: 10001:10001
      pids-limit: 512

      # Both: size=512m is performance, the three flags before it are security.
      tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
    env:
      clear:
        HOTCELL_DIR: /run/hotcell/cell          # see "General" below
```

And the app's half, mounting the same volume:

```yaml
# config/deploy.yml — the app
servers:
  web:
    hosts: [ ... ]
    options:
      group-add: 10001                          # the cell's gid; see "The group both sides share"
  jobs:
    hosts: [ ... ]
    options:
      group-add: 10001

volumes:
  - hotcell-sockets:/run/hotcell/images         # $HOTCELL_ROOT/<cell name>

env:
  clear:
    HOTCELL_ROOT: /run/hotcell
    HOTCELL_GROUP: 10001                        # must match group-add above
```

Without Kamal, the same two containers need `--volume hotcell-sockets:/run/hotcell/cell` and the flags
under "Security" on the cell, and `--volume hotcell-sockets:/run/hotcell/images`, `--group-add 10001` and
`HOTCELL_ROOT=/run/hotcell` on the app.

The two mount paths differ, and only the volume name has to match. A cell always writes its sockets to
`HOTCELL_DIR`. The app resolves a cell's name under `HotCell.root`, so a cell named `images` is found at
`/run/hotcell/images`.

Give each cell its own volume. Two accessories sharing one would write `work.sock` over each other.

### Performance

**These have no defaults.** Docker applies no limit to a flag you omit, so a cell without them can take
the whole host. Tune each one to your workload and your hardware. The values below are the worked example
from this document, not recommendations.

| Flag | Example | Tune it from |
| --- | --- | --- |
| `cpus` | `2` | The share of the host this cell may use. Start the cell's `concurrency` at twice this number. |
| `memory` | `2g` | The cgroup limit, counting every worker and the tmpfs. Size it from `concurrency × peak RSS` plus the tmpfs. Keep it above the cell's `memory`. |
| `memory-swap` | `2g` | Set it equal to `memory`. Omit it and Docker allows twice `memory` in swap, so the memory limit no longer holds. |
| `tmpfs` size | `size=512m` | Scratch for all concurrent workers together. It pairs with `file_size × concurrency`. |
| `ulimit: stack` | leave it unset | A container inherits the Docker daemon's value, normally 8MB, and that is where to leave it. Lowering it buys a worker about 24MB more room at 2MB, and nothing at all for an operation that shells out. It costs far more than it buys: a thread that overflows the smaller stack dies on `SIGSEGV`, which the cell reports as `killed`/`memory` — a permanent verdict written against the caller's file, and identical to a genuine memory breach, so it sends you to the wrong setting. Raise the cell's `memory` instead. It belongs here rather than in `config.rb` because glibc reads it at exec, before `Process.setrlimit` could run. |

### Security

**Use these values.** They are what a cell is for. Omit one and the protection is gone, while the cell
serves requests exactly as before.

| Flag | Recommended | What it does |
| --- | --- | --- |
| `network` | `none` | Removes every network interface. A tool that is persuaded to fetch a URL cannot reach anything. Set it as an accessory key, not under `options:`. |
| `read-only` | `true` | Makes the root filesystem read-only. A cell writes only to `/tmp` and to the socket volume. |
| `tmpfs` flags | `nosuid,nodev,noexec` | `noexec` prevents execution from scratch, which is where a dropped payload lands. |
| `cap-drop` | `ALL` | Removes every Linux capability. |
| `security-opt` | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | `10001:10001` | Runs the cell as a high uid outside any host user range, with no home directory and no shell. |
| `pids-limit` | `512` | Bounds the number of processes in the cell. It must clear `concurrency` plus the threads and subprocesses one toolchain starts, so check it when you raise `concurrency`. |

### General

Environment variables. The image sets all of them, so set one only to override it.

| Variable | Default | What it does |
| --- | --- | --- |
| `HOTCELL_DIR` | `/run/hotcell/cell` | Where the cell creates `work.sock` and `control.sock`. The app must use the same directory. |
| `HOTCELL_OPERATIONS` | `/hotcell/operations` | The directory the cell loads at boot, in sorted order. |
| `HOTCELL_CONFIG` | `/hotcell/config.rb` | Loaded before the operations, if the file exists. |
| `HOTCELL_WORKSPACE` | a directory under `Dir.tmpdir` | Where each request's directory is made and removed. On the accessory this is the tmpfs. |
| `HOTCELL_HEALTH_TIMEOUT` | `5` | Seconds `hotcell-health` waits for an answer before it reports unhealthy. |
| `HOME` | `/tmp` | Bundler needs one, and the cell's user has no home directory. A worker replaces it with a directory made for the request and removed with it. |

## The volume

Nobody creates it. Docker creates a named volume when the first container that references it starts, so
either the cell or the app makes it, whichever starts first.

**Boot order does not matter.** An empty named volume takes its ownership from the image of whichever
container mounts it, even when an earlier container already mounted it, as long as it is still empty. An
app that starts first gives the volume its own ownership; the cell then mounts it while it is still empty
and takes it back. Once the cell creates its sockets the volume is no longer empty, and ownership stops
changing.

Two mistakes both fail the same way, as `EACCES` when the cell creates its socket at boot.

**The mount point must exist in the cell's image, owned by the cell's user.** The image the installer
writes creates `/run/hotcell/cell` and chowns it, not only `/run/hotcell`. If an image creates only the
parent, Docker creates the last level as root, and the cell cannot create a socket in it. The app's image
needs nothing at its own mount point.

**A bind mount inherits nothing.** It keeps the host directory's ownership. A bind mount in development
needs the host directory chowned to `10001`, or the container run as the host user. Use named volumes in
production.

## The socket's file mode

The cell creates both sockets `0666`. A Unix socket is a filesystem object, and `connect` needs write
permission on it. The two sides do not share a uid — the cell runs as `10001` and the app runs as whatever
its own image sets — so `0600` gives `EACCES` on the app's first request.

The mount topology is what limits access: the directory is a volume mounted into two containers only.

## The group both sides share

Set `HotCell.group` to the cell's gid, and put the application in that group:

```yaml
# config/deploy.yml — the app
servers:
  web:
    options:
      group-add: 10001
```

**Why it is needed.** An operation that hands a tool a filename does not copy the input. It re-opens the
descriptor as `/dev/fd/N`. That is a fresh open, and the kernel rechecks it against the **cell's** user
rather than the caller's. The two sides do not share a uid, so a mode `0600` file the application owns
gives `EACCES`. An Active Storage tempfile is exactly that.

Six of the eight shipped Active Storage operations hand a tool a filename. The two `magick` ones do not,
because they stage first.

**What the client does with it.** It puts each descriptor in the group and narrows the mode on the way
out: `0640` for an input, `0620` for an output. It does this through the open file rather than a path, so
it names nothing.

**What that buys, and what it does not.** A cell may read an input and write an output. It may not write
an input or read an output, and it cannot widen either, because it does not own these files and
`cap-drop ALL` leaves it no capability that overrides a mode. The application must own them and be in the
group, which is what lets it set the group at all.

**Do not share a uid instead.** It is the obvious shortcut and it costs two things. The cell would own the
files, so it could set any mode it liked and the one-way rule would stop holding. And a cell that escaped
its container would land on the application's own user on the host, where it can read the environment of
the application's processes. Keep the uids apart and share only the group.

**How it fails.** Loudly, on the first operation that hands a tool a filename. Operations that read the
descriptor directly keep working, which is why `echo` alone does not detect it. See "Checking a deployed
cell".

**What warns first.** `HotCell.describe_cells` checks two things at boot, and warns rather than raising,
like every other boot check here.

- **Whether this process holds `HotCell.group`.** A missing `group-add` is then visible before any traffic
  depends on it. This check is local and needs no cell, so it reports even when every cell is down.
- **Whether the cell runs in that group.** `describe` reports the groups a cell holds, and the client
  compares them. The number lives in your deploy file and the cell's gid is baked into an image built
  somewhere else, so nothing else would catch a cell image that moved its gid. A cell too old to report
  them says nothing.

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

## Application settings

Per registered cell. They set how the application responds to what a cell answers.

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]              # unset turns every cell off
HotCell.group = ENV["HOTCELL_GROUP"]&.to_i      # the cell's gid; unset where both sides are one user

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
| `timeout:` | `30` | Seconds this caller waits for an answer to a work request. It must clear the cell's `answer_within`. |
| `control_timeout:` | `5` | Seconds this caller waits for `describe` or `metrics`. The supervisor answers both inline, with no fork and no queue, so this is short on purpose and must not be raised toward `timeout`. It is what bounds app boot when a cell accepts connections and never answers, and what lets a health check report a wedged cell instead of waiting out a work timeout. |
| `permanent:`, `transient:` | the gem's classes | The exception classes the application raises for each side of the split. `transient` must not descend from `permanent`, and the client refuses to start if it does. |
| `on_contract_skew:` | — | Called when a cell answers `protocol`, so a version mismatch is visible to an application that rescues broadly. |

## Settings that trade one for the other

**`max_requests_per_worker` above `1`** lets one request reach another. A worker holds each of its
requests in the same address space, so an input that runs code can read and change every later request
that worker serves. [ADR 0001](../adr/0001-reuse-workers-across-requests.md) records the measurements and
the trade.

**`concurrency`** sets how many requests hold bytes in the cell at once. Files are not isolated between
concurrent workers, so this value is also the width of that exposure. See "What is not isolated".

## Making the numbers agree

Nothing checks these three for you.

- The client's `timeout` must be more than the cell's `answer_within`, which is
  `queue_wait + deadline + 1`. Below it, a saturated cell reaches the caller as a transport failure
  instead of as `capacity` or `killed`. The client warns at boot, and `describe` reports the number.
- The cell's `memory` must stay below the container's `memory`. At equal values the cgroup fires first,
  and a cgroup kill is a `SIGKILL` with no diagnostic.
- `file_size × concurrency` must fit the tmpfs. Above it, concurrent workers fill scratch and requests
  fail with `ENOSPC` instead of with a limit verdict.

Three things are fixed and cannot be configured: the one-second grace between the signal to a worker and
the kill of its process group, the absence of an `RLIMIT_CPU`, and the socket file mode.

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
Ruby, its gems, and its socket behaviour — not the work your operations do.

`bin/example-image` builds an image to try it against. CI runs both on every push.

### What it does not verify

**It does not check your accessory.** `bin/conformance` supplies its own flags, so it proves the image
works when the flags are right. It never reads your Kamal configuration, and it passes against an image
you are about to deploy with `cap-drop` missing.

Of the security flags, it observes three from inside the cell: `network: none` (the only interface is
`lo`), `read-only` (the root filesystem refuses a write), and the tmpfs `noexec` flag. It does not observe
`cap-drop`, `no-new-privileges`, the uid, the tmpfs `nosuid` and `nodev` flags, or `pids-limit`.

It does check the shared group, because it runs the cell as `10001` against files a different user owns.
`example.reopen` proves a cell can open an input by name, and `example.tamper` proves it can do nothing
else with either file. What it cannot check is your application's group membership: its own driver owns
the files as root, which needs no membership to set a group. That one fails as `EPERM` in the application
rather than in the cell.

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
mistake above, and Docker rejects the container at boot with exit status 125.

To check a deployed cell, read the flags on the running container:

```
docker inspect <container> --format '{{json .HostConfig}}' | jq '{
  NetworkMode, ReadonlyRootfs, CapDrop, SecurityOpt, PidsLimit, Memory, MemorySwap, Tmpfs
}'
```

## Checking a deployed cell

`describe` and `metrics` answer on the control socket, which a descriptor never crosses. They report a
healthy cell whose work socket the application cannot use at all — the two volume-ownership mistakes above
fail as `EACCES` on the first real request, and nothing on the control socket says so.

So carry two trivial operations that cross the work socket, permanently, and call them from whatever page
or probe reports the cell's health. `examples/operations/echo.rb` and `examples/operations/reopen.rb` in
the hotcell repository are written for this. Copy both into your own `operations/`. Neither loads a
library or runs a tool, so together they cost the blast radius nothing.

**They prove different things, and you need both.** `echo` reads both descriptors directly, so one round
trip proves descriptor passing end to end. `reopen` opens both **by name**, which is what every operation
that hands a tool a filename does. A cell with the shared group missing answers `echo` perfectly and fails
`reopen` with `EACCES`. That is the whole difference between a cell that works and one that fails on every
real conversion, and only `reopen` sees it.

**`reopen` covers both directions on purpose.** An input is readable by the group and an output is
writable by it, and those are separate permissions a cell can hold one of. Most shipped operations
re-open only their source, but the ffmpeg video previewer re-opens its destination too. A probe that read
the input alone would go green on a cell where every video preview fails on the write.

Four checks together say whether a cell is usable: `describe` for the inventory, `metrics` for the
supervisor, one `echo` for the socket that real files travel over, and one `reopen` for the group they
travel in, in both directions.

When you move an existing application onto a cell, consider doing it in phases. A first phase that deploys
the accessory and confirms those four answers correctly separates a deployment problem from a conversion
problem, before any traffic depends on it.

## Load testing a configuration

[docs/TUNING.md](TUNING.md) covers arriving at these numbers for your own workload — what to instrument
first, which settings to start generous on and why, and what to watch.

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
