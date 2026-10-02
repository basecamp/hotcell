# Cell settings

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
| `sweep_interval` | `10` | How often, in seconds, the supervisor looks for the directories that killed requests left behind. When it finds one, it forks a sweeper process to delete them. The sweeper runs under `deadline` like a worker, so the supervisor and the requests in flight never wait on the deletion. |
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

### General

Environment variables. The image sets all of them unless the table says otherwise, so set one only to
override it.

| Variable | Default | What it does |
| --- | --- | --- |
| `HOTCELL_DIR` | `/run/hotcell/cell` | Where the cell creates `work.sock` and `control.sock`. The app must use the same directory. |
| `HOTCELL_OPERATIONS` | `/hotcell/operations` | The directory the cell loads at boot, in sorted order. |
| `HOTCELL_CONFIG` | `/hotcell/config.rb` | Loaded before the operations, if the file exists. |
| `HOTCELL_WORKSPACE` | a directory under `TMPDIR` | Where each request's directory is made and removed. On the default accessory this is the tmpfs. Must be absolute. Emptied at boot — see "Where scratch lives". |
| `TMPDIR` | unset, so `/tmp` | The scratch, emptied at boot of every entry the cell's uid owns. On the accessory `/tmp` is the cell's own mount. Under `hotcell --development` it is only the scratch's parent and is never swept — see "Where scratch lives". |
| `HOTCELL_HEALTH_TIMEOUT` | `5` | Seconds `hotcell-health` waits for an answer before it reports unhealthy. |
| `HOME` | `/tmp` | Bundler needs one, and the cell's user has no home directory. A worker replaces it with a directory made for the request and removed with it. |
| `OMP_NUM_THREADS` | `2` | The OpenMP pool size libvips and ImageMagick use. Match it to `cpus`. See "Bound the OpenMP thread pools". |
| `OMP_THREAD_LIMIT` | `8` | The ceiling on that pool, including a library that raises the count itself. |
| `MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT`, `MAGICK_DISK_LIMIT` | unset | ImageMagick's pixel cache limits. The scaffold installs no ImageMagick; an image that does sets these from the container's `memory`, the scratch and `concurrency`. See [docs/IMAGEMAGICK.md](IMAGEMAGICK.md). |
