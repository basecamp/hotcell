# Cell settings

This page lists the settings that a cell reads at boot: its scheduling settings, its request limits, the
environment variables, and the order in which it loads files. For the container flags, see
[Container](container.md). For how to choose the numbers, see [Tuning](tuning.md).

The code lives in
[`hotcell-server/lib/hot_cell/configuration.rb`](../hotcell-server/lib/hot_cell/configuration.rb) and
[`hotcell-server/lib/hot_cell/limits.rb`](../hotcell-server/lib/hot_cell/limits.rb).

## Configure a cell

Call `HotCell.limits` once, in `hotcell/config.rb`. Every setting has a default, so set only what you
change. For example:

```ruby
# hotcell/config.rb
HotCell.limits concurrency: 4, queue_size: 8, queue_wait: 10, deadline: 30,
               max_requests_per_worker: 1, control_deadline: 5,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2, open_files: 256
```

An unknown setting raises `HotCell::ConfigurationError`, and so does an explicit `nil` for a request
limit.

## Scheduling settings

| Setting | Default | Description |
| --- | --- | --- |
| `concurrency` | `4` | Workers that run at once, and the number of slots. Start at twice `cpus`. See [Settings that trade isolation](#settings-that-trade-isolation). |
| `queue_size` | `8` | Connections that can wait for a worker. When `running + queued` reaches `concurrency + queue_size`, the cell answers `capacity`. To refuse instead of queueing, use `0`. |
| `queue_wait` | `10` | Seconds that a queued connection can wait before the cell answers `capacity`. A saturated cell then answers with a verdict instead of holding the caller until the caller's own timeout. |
| `max_requests_per_worker` | `1` | Requests that one worker serves before the cell discards it. `1` forks for each request. `:unlimited` keeps a worker for the life of the cell. See [Settings that trade isolation](#settings-that-trade-isolation). |
| `control_deadline` | `5` | Seconds that a control connection can take to send its request. |
| `sweep_interval` | `10` | How often, in seconds, the supervisor looks for the directories that killed requests left behind. When it finds one, it forks a sweeper process to delete them. The sweeper runs under `deadline` like a worker, so the supervisor and the requests in flight never wait on the deletion. |

## Request limits

These four settings are sized like performance settings, and they exist as limits on a hostile input.

| Setting | Default | Description |
| --- | --- | --- |
| `deadline` | `60` | Maximum wall-clock seconds for one request. The supervisor kills the worker's process group and answers `killed` with cause `deadline`. This is the only bound on a stuck or deliberately slow input. |
| `memory` | `1536MB` | `RLIMIT_DATA` for each worker, and the bound on a decompression bomb. A breach answers `killed` with cause `memory`. The floor is `1024MB`: a cell or an operation below it raises `HotCell::ConfigurationError` and doesn't boot. |
| `file_size` | `64MB` | `RLIMIT_FSIZE` for each worker. A breach raises `SIGXFSZ` and answers `killed` with cause `fsize`. |
| `open_files` | `256` | `RLIMIT_NOFILE` for each worker. |

`MB` here means 1024² bytes. Every limit must be positive.

An operation can declare its own `limits`. Those values narrow the limit for that operation's requests,
and never widen it, because the cell's values are the ceiling. See
[Operation API](operation-api.md#limitsvalues). This is [invariant 6](design/invariants.md).

`memory` doesn't multiply by `concurrency`. It's an address-space charge on one worker, and about 450MB of
it is Ruby's own reservation. See [Tuning](tuning.md#sizing-guidelines).

On macOS, `RLIMIT_DATA` can't be set, so a cell there runs with `memory` unenforced and warns once. Every
other limit is enforced on both platforms. See [experiment 17](design/experiments.md).

### Values that you can't configure

- The one-second grace between the signal to a worker and the kill of its process group.
- The absence of an `RLIMIT_CPU`. The deadline covers CPU use, and it also catches a worker that is blocked
  on a stuck subprocess, which uses no CPU. `HotCell::Limits` explains the rest.
- The sockets' file mode, `0660`. See [Client API](client-api.md#the-shared-group).

## Settings that trade isolation

**`max_requests_per_worker` above `1`** lets one request reach another. A worker holds each of its
requests in the same address space, so an input that runs code can read and change every later request
that the worker serves. [ADR 0001](../adr/0001-reuse-workers-across-requests.md) records the measurements
and the trade.

At `:unlimited`, it also gives up the deadline. A worker reports itself idle when it finishes, and the
supervisor can't tell a true report from a false one, so a worker that lies stops being timed. At every
finite setting, the supervisor still retires the worker and kills it after a grace period. At `:unlimited`,
nothing retires it, and the cell can't end it. Prefer a finite number, however large.

**`concurrency`** sets how many requests hold bytes in the cell at once. Files aren't isolated between
concurrent workers, so this value is also the width of that exposure. See
[Worker isolation](design/worker-isolation.md).

## Environment variables

The installed `Dockerfile` sets all of these unless the table says otherwise, so set one only to override
it.

| Variable | Default | Description |
| --- | --- | --- |
| `HOTCELL_DIR` | `/run/hotcell/cell` | Where the cell creates `work.sock` and `control.sock`. The application must reach the same directory. |
| `HOTCELL_OPERATIONS` | `/hotcell/operations` | The directory of operation files that the cell loads at boot. See [Load order](#load-order). |
| `HOTCELL_CONFIG` | `/hotcell/config.rb` | The configuration file that the cell loads before the operations, if the file exists. |
| `HOTCELL_WORKSPACE` | a directory under `TMPDIR` | Where the cell makes and removes each request's directory. On the default accessory, this is the tmpfs. Must be absolute. Emptied at boot. See [Scratch](scratch.md#boot-sweep). |
| `TMPDIR` | unset, so `/tmp` | The scratch. Emptied at boot of every entry that the cell's uid owns. On the accessory, `/tmp` is the cell's own mount. Under `hotcell --development`, it's only the scratch's parent and is never swept. See [Scratch](scratch.md#boot-sweep). |
| `HOTCELL_HEALTH_TIMEOUT` | `5` | Seconds that `hotcell-health` waits for an answer before it reports unhealthy. |
| `HOME` | `/tmp` | Bundler needs a home directory, and the cell's user has none. A worker replaces `HOME` with a directory made for the request and removed with it. |
| `OMP_NUM_THREADS` | `2` | The OpenMP pool size that libvips and ImageMagick use. Match it to `cpus`. See [Bound the OpenMP thread pools](container.md#bound-the-openmp-thread-pools). |
| `OMP_THREAD_LIMIT` | `8` | The ceiling on that pool, including for a library that raises the count itself. |
| `MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT`, `MAGICK_DISK_LIMIT` | unset | ImageMagick's pixel cache limits. The installed `Dockerfile` installs no ImageMagick. An image that installs it sets these from the container's `memory`, the scratch, and `concurrency`. See [ImageMagick](imagemagick.md). |

## Load order

At boot, the cell does the following, in order:

1. Loads `HOTCELL_CONFIG`, if the file exists.
2. Requires every `.rb` file under `HOTCELL_OPERATIONS`, including subdirectories, in sorted path order.
   Requiring an operation's file is what makes the cell serve it.
3. Runs every operation's `before_fork` blocks.

For an operations file that redeclares a shipped operation's limits, see
[Change a shipped operation's limits](operation-api.md#change-a-shipped-operations-limits).

A cell for custom operations names `hotcell-server` in its `Gemfile` directly, plus the gems that its
operations use. It needs the Active Storage server gem only for the shipped operations:

```ruby
# hotcell/Gemfile -- the cell
gem "hotcell-server"
gem "my_image_processor"
```

## Development mode

`hotcell --development` boots a cell as a plain process, without a container, for example beside the Rails
server in `Procfile.dev`. The resource limits and the deadline apply as they do in a container.

At boot, a cell empties its `TMPDIR` of every entry that its uid owns. When `TMPDIR` is unset, it empties
the system temporary directory. On a developer's machine, that's `/tmp`, or on macOS the per-user
`TMPDIR` that every shell sets, and both are shared with everything else that the developer runs.

With `--development`, the cell never sweeps the directory that it's given. Its scratch is
`hotcell-<HOTCELL_DIR with slashes as dashes>` beneath that directory. `HOTCELL_WORKSPACE` defaults to a
directory under the scratch. If you point it elsewhere, the cell sweeps its parent too, with or without
`--development`. See [Scratch](scratch.md#boot-sweep).
