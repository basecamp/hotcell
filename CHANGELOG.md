# HotCell changelog

This changelog covers five gems, which release together on the same version:

- `hotcell-core`
- `hotcell-client`
- `hotcell-server`
- `activestorage-hotcell-client`
- `activestorage-hotcell-server`

A `Tooling` section records changes to the checks and scripts in `bin/` and `examples/`, which ship in no
gem but are what an operator runs against their own image.

## next / unreleased

### HotCell::Core

#### Fixed

* `Input#fd_path` stages its input on darwin, where `open("/dev/fd/N")` is a `dup` of fd N and shares its
  offset rather than reopening the file at zero. A tool that opens the path more than once — libvips does,
  once per candidate loader, to sniff a format — walked that offset forward, so a file whose loader is late
  in the priority order came back `unreadable` with no error recorded. This only ever affected an
  uncontainerized cell on macOS, which is the supported development path; Linux reopens and is unchanged.
  The cost on darwin is a copy and the `RLIMIT_FSIZE` ceiling that bounds one: an input larger than the
  operation's `file_size` is refused there as a permanent `fsize` verdict rather than read in place. A
  refusal for a file too large to copy, in place of a wrong answer for an ordinary one.

* `Input#path` copies from byte zero rather than from wherever the caller left the descriptor, and no
  longer moves it. The descriptor arrives over `SCM_RIGHTS` and carries the caller's own file offset, so an
  application that handed over an IO it had already read from was staged a copy with its prefix missing,
  where `/dev/fd/N` reads the file whole.


## v0.3.0 / 2026-09-01

### HotCell::Client

#### Added

* The installed `Dockerfile` strips the setuid and setgid bits off every binary in the image as its last root step, so the strip covers anything a `RUN` above it installed rather than the base image alone. The cell already runs unprivileged under `--cap-drop ALL` and `--security-opt no-new-privileges`, which make `mount`, `su` and the rest inert, so this removes escalation tools a security image should not carry rather than closing a reachable path. The scaffold also now documents what it deliberately does not do for you: build with `docker build --pull`, pin a base digest and refresh it on a schedule if you need to name the exact image you shipped, and commit a platform-correct `Gemfile.lock` and build frozen for a reproducible dependency graph. Frozen mode is off by default so a freshly installed scaffold builds before you have generated a lockfile. An upgrade leaves an existing `Dockerfile` alone, so a cell installed before this needs the strip added by hand and the image rebuilt.

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

* `activestorage-hotcell-server` requires `mini_magick >= 5.2.0` and `ruby-vips >= 2.2.1`. The declared floors were `4.0` and `2.2`, but `MagickOperation` sets `MiniMagick.restricted_env=` at require time and `VipsOperation`'s `before_fork` guard requires `Vips.block_untrusted`, neither of which exists at those floors. A bundle that satisfied the gemspec could resolve `mini_magick` 5.1.2 or `ruby-vips` 2.2.0 and fail to boot — a `NoMethodError` on the magick side, a fail-closed `ConfigurationError` on the vips side — taking the whole conversion toolchain offline.

* `MiniMagick.cli_env` carries the cell's `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT`, so `magick` runs under the image's bound rather than sizing its pool from the host's cores. `MiniMagick.restricted_env` is what had removed them.


### Tooling

#### Changed

* `bin/conformance` verifies the container flags it claims rather than asserting them. The isolation check read the network interfaces, whether the root took a write, whether scratch was `noexec`, and an exec'd tool's environment — it never read the bounding capability set, so `--cap-drop ALL` could be dropped from the run and every check still passed. The read-only check was weak the same way: `File.writable?("/")` is false for the cell's non-root user whether or not the root is read-only. The `isolation` operation now reports what the kernel exposes — the bounding capability set and the no-new-privileges bit from `/proc/self/status`, the uid, and the root mount's read-only option from `/proc/self/mounts` — and the battery requires each. A field the cell cannot read comes back `nil` and fails, so a run that cannot see a flag is never mistaken for one that set it.

* `bin/conformance` runs its own negative controls: it re-invokes itself once per flag with `HOTCELL_CONFORMANCE_DROP`, booting without `network`, `read-only`, `cap-drop` and `no-new-privileges` in turn, and requires each run to fail at that flag's own assertion rather than merely exiting non-zero. The `tmpfs-noexec` negative is decided by probing the runtime, so a runtime that force-mounts `noexec` reports `SKIP` with the reason instead of passing vacuously. The isolation checks run first, before the timing-sensitive deadline and overload checks, so a dropped flag fails there rather than behind a flake. `examples/gate` is a fast container-free guard that drives the isolation check with fabricated results, proves it rejects every insecure or unreadable value, and holds the negatives' expected messages against the battery's assertions so a reworded assertion cannot rot a negative into a grep that never matches.

* `bin/conformance` and `bin/load` no longer pass `--ulimit stack=2097152:2097152`. `docs/DEPLOYMENT.md` forbids a lowered stack — an overflow becomes a `SIGSEGV` the supervisor reports as a transient `killed`/`crashed` — so the helpers were measuring a shape operators are told not to deploy. `examples/gate` asserts neither script sets it.

#### Fixed

* `docs/DEPLOYMENT.md` no longer tells operators that conformance cannot observe `cap-drop`, `no-new-privileges` or the uid, and that `read-only` is checked by attempting a write. All four were true before the checks above and false after.


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
