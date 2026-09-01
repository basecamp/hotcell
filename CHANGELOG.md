# HotCell changelog

This changelog covers five gems, which release together on the same version:

- `hotcell-core`
- `hotcell-client`
- `hotcell-server`
- `activestorage-hotcell-client`
- `activestorage-hotcell-server`

## v0.3.0 / 2026-09-01

### HotCell::Client

#### Breaking

* `HotCell.describe_cells` no longer warns about a client whose operation the cell does not carry, and `HotCell.clients` is gone with it. The check could not tell a client the application calls from one it merely loaded, so a cell carrying a subset of what a gem ships warned on every boot. A request for an operation the cell does not carry is refused as `unsupported`, naming the operation, and that failure is transient and reaches the application's error reporting. An application that wants a boot check can write one over its own configuration.

#### Fixed

* The installed `Dockerfile` sets `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` to the container's `cpus`. OpenMP sizes its thread pool from the host's core count, and a container's `cpus` quota is a CFS quota rather than an affinity mask, so libvips and ImageMagick asked a 98-core host for 98 threads however small the cell's share of it. A thread stack is 8MB of private anonymous memory, which `RLIMIT_DATA` charges, so the pool alone cleared the cell's `memory` limit — and libgomp calls `exit(1)` on the first `pthread_create` it cannot satisfy. An upgrade leaves an existing `Dockerfile` alone, so a cell installed before this needs both added by hand and the image rebuilt. `docs/DEPLOYMENT.md` covers why the guard has to be a test rather than a deploy to beta: the failure exists only at production's core count.

* The installed `Dockerfile` applies Debian's pending security patches with an `apt-get upgrade` after the `FROM`. `docker build --pull` takes the newest base tag, but the tag itself can sit behind an advisory already in `trixie-security` until [docker-library/ruby](https://github.com/docker-library/ruby) rebuilds it, so a clean build shipped a fixable High that no rebuild of the cell could clear. Upgrading during the build makes the image's patch level its own rather than upstream's release cadence, and stops the class rather than the one advisory. An upgrade leaves an existing `Dockerfile` alone, so a cell installed before this needs the line added by hand and the image rebuilt.

### HotCell::Core and HotCell::Server

#### Added

* A worker's file descriptor 2 is a pipe to the supervisor, which drains it as it runs and attaches the last 512 bytes to the `worker.killed` that reports its death, as `hotcell.stderr`, and to the failure the caller receives, as `stderr`. A C library that calls `exit()` raises nothing, so `worker.crashed` is never written and the connection carries a bare `crashed`; the account of what happened was on fd 2, which goes to the container runtime's log driver, where the fleet's collector drops complete non-JSON lines at ingest. `libgomp: Thread creation failed: Resource temporarily unavailable` is the line this exists for. The field makes a death legible rather than shipping a cell's stderr anywhere, so a worker that warns and then answers normally reports nothing. The capture is best effort and untrusted: fd 2 stays non-blocking so a warning written from inside libvips can never wait on the supervisor's scheduling, and everything a worker spawned inherits the descriptor. `docs/LOGS.md` states what the field is and is not.

### HotCell::Server

#### Added

* `request`, `request.abandoned`, `worker.crashed`, `worker.killed` and `worker.undispatchable` carry `hotcell.op`, the operation the line is about. A cell runs several operations at once and they do not share limits, so `worker.killed cause=fsize` on a host serving three PDF operations named none of them, and no join was available elsewhere: the response carries no operation, and `hotcell_killed` is tagged `cell` and `cause` only. The worker parses the name out of the request; the supervisor, which never reads one, learns it from the worker's report and holds it, because a killed worker cannot write its own `worker.killed`. Where the name is not known the field is `null` rather than an earlier request's name. See [docs/LOGS.md](docs/LOGS.md).

* `worker.undispatchable` is the one line where the supervisor reads a request, since the worker died before the dispatch write and nothing else has read it. It peeks rather than reads, taking neither the bytes nor the caller's descriptors off the connection, and never waits for a request that has not arrived.

#### Fixed

* `Operation#run_tool` carries `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` from the cell's environment into the environment it writes for a tool. A tool sees only what its operation wrote for it, so the image's bound would otherwise have applied to in-process libvips and to nothing the cell execs.

### ActiveStorage::HotCell::Server

#### Fixed

* `MiniMagick.cli_env` carries the cell's `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT`, so `magick` runs under the image's bound rather than sizing its pool from the host's cores. `MiniMagick.restricted_env` is what had removed them.


## v0.2.0 / 2026-08-25

### HotCell::Client and HotCell::Server

#### Security

* The file-size verdict is now earned from the failed write rather than read off a signal. Workers share a uid, so one worker could signal another and have the supervisor write a permanent `fsize` or `memory` judgment against the victim's unrelated input, which Active Storage would then cache forever. Every signal but the supervisor's own deadline kill is now `crashed` and transient. (#25)
* Each request now gets a `$HOME` name no earlier request held, under a slot directory whose mode is reasserted first. A tool that reached code execution could `chmod 0500` its own configuration directory, defeating both the worker's delete and the supervisor's rename, and hand the next request the tree that had refused to go. (#22)
* A failed scratch removal is retried with the modes put back, and logs `slot.unswept` when it still fails. A `chmod 0500` on a directory a conversion wrote left one tree per request on the tmpfs, readable by every later request on the slot, and `sweep` reported nothing. (#22)

#### Fixed

* `Cell#describe` reads the description inside a rescue. A response with a correctly framed shape but the wrong types raised out of `describe_cells`, which the README recommends calling from `after_initialize` where nothing rescues it — so a cell answering badly could stop a Rails application from booting. An unreadable description is now logged and ignored, which is what an unreachable cell already returned. (#29)
* `HotCell.register` raises `ConfigurationError` unless `timeout` and `control_timeout` are positive and finite. A `nil` timeout built no deadline at all, so a cell that accepted a connection and never answered held the caller for good. (#34)
* The installer writes `hotcell/operations/.keep` rather than shipping it as a template. `hotcell-client.gemspec` selects `Dir["lib/**/*"]`, which does not match a dotfile, so the published v0.1.0 installer wrote a scaffold whose generated `Dockerfile` could not build. (#26)

## v0.1.0 / 2026-08-19

- Birthday!
