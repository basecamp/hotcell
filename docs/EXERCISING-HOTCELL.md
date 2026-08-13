# Exercising a Cell — sample operations, conformance, and load

The center of this is **one reusable, documented set of sample operations** — plus the thin client classes an
app uses to call them, and one shared **battery** of checks built from them — that exercise a cell's behavior
independent of *how* it is deployed. Three consumers use that battery:

- **`rake test:devcell`** — runs the battery against the real `exe/hotcell` **development process**, natively. Part
  of the test suite, on Linux **and** macOS.
- **`bin/conformance`** — runs the battery (plus container-only isolation checks) against a **container image**,
  to prove the image actually supports hotcell. In CI on Linux, and a tool a user runs against their own image.
- **`bin/load`** — drives the operations at **volume** against the container.

The operations, their client classes, and the battery are the deliverable. The consumers are thin.

## Layout

```
examples/
  operations/   # sample operations the cell loads via HOTCELL_OPERATIONS
  lib/          # thin client classes for those operations, and the shared battery of checks
  devcell       # the native runner: boots exe/hotcell, runs the battery, proves clean shutdown
  conformance   # the driver bin/conformance runs inside a second container
  load          # the driver bin/load runs inside a second container
  Gemfile       # the driver's gems: hotcell-core and hotcell-client, from this repository
bin/
  conformance   # container: does this image support hotcell?  (CI on Linux)
  load          # container, at volume  (manual; a bounded run may gate CI later)
Rakefile
  test:devcell  # native dev process: does the development configuration work?  (default task; Linux + macOS)
```

`examples/operations` is pure Ruby with **no external toolchain** — nothing from libvips/ImageMagick/ffmpeg —
so the same operations run on macOS, where those tools and Docker are absent. The consumers drive the cell
through the **thin client classes** in `examples/lib` rather than a raw `hot_cell/core` `Connection`: simpler
and clearer, and the wrapper adds negligible latency, so the load numbers still measure the cell.

## The sample operations

Each is parameterized by payload, so one operation covers a range of inputs. They double as worked examples of
how to write an operation.

| op | behavior | what it proves |
|----|----------|----------------|
| `echo` | read a message from the input fd, write it back to the output fd | descriptor passing (SCM_RIGHTS) round-trips; a fast throughput baseline |
| `sleep` | block for `seconds` | the deadline kills and answers; head-of-line behavior under load |
| `greedy` | allocate `megabytes` | the `memory` clamp → `killed: memory` (where enforceable) |
| `overflow` | write `megabytes` to the output | the `file_size` clamp → `killed: fsize` |
| `crash` | raise, or die by signal | worker death → a clean verdict, no orphan, continued service |
| `spawn` | fork a grandchild that outlives the worker | the group kill leaves nothing behind |
| `probe` | whether a pid is alive, asked from inside the cell | how the battery watches `spawn`'s grandchild die, in any pid namespace |
| `isolation` | report interfaces, root writability, scratch noexec, a tool's environment | the container-only checks, from the only place that can make them |

They mirror behaviors that already exist as in-repo fixtures (`test.blocking`, `test.greedy`,
`test.overflowing`, `test.broken`, `test.spawns`, `test.reverse`); the fixtures stay the reference.

## The battery

One list of checks, in `examples/lib`, that both `rake test:devcell` and `bin/conformance` run:

- `describe` on the control channel lists the expected operations.
- `echo` round-trips a message and comes back `ok`.
- `sleep` past the deadline → `killed: deadline`.
- `greedy` / `overflow` → `killed: memory` / `killed: fsize` (memory skipped where `RLIMIT_DATA` is
  unenforceable, e.g. macOS).
- `crash` → a clean verdict, no orphaned process, and the cell keeps serving afterward.
- offered overload → `capacity`, not an unbounded wait.

`bin/conformance` adds the container-only checks the native run cannot make: the isolation flags hold —
`network: none` (an op that reaches for the network must fail), read-only root, tmpfs `noexec`, an empty
environment.

## `rake test:devcell` — does the development configuration work?

Boots the real `exe/hotcell` as a plain host process with `examples/operations`, runs the battery through the
client classes, then `SIGTERM` and asserts exit 0, no orphaned processes, socket and workspace cleaned. This is
the guarantee that a developer can run the uncontainerized cell the way the README describes, on their own
machine. It is Docker-free on purpose — the macOS runners cannot run Docker, and a descriptor cannot cross the
host→VM boundary.

It is a rake task added to the **default task**, so it runs with the rest of the suite, and it runs in CI on
**Linux and macOS**.

## `bin/conformance` — does this image support hotcell?

The real use case: *someone builds their own hotcell image.* `bin/conformance IMAGE` proves it.

- Launches `IMAGE` as a cell with the accessory's real flags — `network: none`, cap-drop, read-only root,
  tmpfs — and `examples/operations` mounted, and asserts:
  - the server process **starts** and creates its socket,
  - it **obeys `HOTCELL_DIR`** — point the socket directory somewhere non-default and the socket appears there,
  - the **battery** passes,
  - the **isolation** holds (the container-only checks above).
- The driver runs the battery from a **second container** over a shared volume, so a descriptor crossing the
  container boundary is part of what's proven — the one real thing `docker/smoke` did. The driver container is
  a stock Ruby image rather than the image under test, so a minimal cell image never needs to carry the
  client's dependencies; it installs `examples/Gemfile` at launch, which is the one step that needs network.
- Exit non-zero on the first failed assertion, so a user or CI can gate on it.
- Runs in **CI on Linux** against our own built image, so the container and isolation path finally has automated
  coverage — the gap `docker/smoke` left.

## `bin/load` — how does it behave under pressure?

The same operations at volume against the containerized cell.

- **Measure** — throughput (req/s at a given `concurrency`), latency p50/p95/p99 split `queued_ms` vs
  `perform_ms`, queue depth over time, `capacity` rejections, the verdict breakdown, worker churn, recovery.
- **Scenarios** — baseline (`echo`, ramp concurrency, find the knee); overload/backpressure (confirm
  `queue_size` and `queue_wait` bound it); slow-vs-deadline (`sleep`); resource bombs (`greedy`/`overflow`);
  worker death (`crash` — *where the deferred deadline-kill no-verdict race is most likely to reproduce*);
  orphans (`spawn`).
- **Knobs** — `concurrency`, `queue_size`, `queue_wait`, `max_requests_per_worker`, `deadline`, `memory`,
  `file_size`, `open_files`.
- Heavy runs are manual; the script takes a duration/scenario so a **tiny bounded run** can also gate in CI.

## What this removes

`docker/smoke` is dropped. `bin/conformance` is its automatable, general replacement: it does what
`docker/smoke` did (mount ops into a hardened container, check the flags, cross a descriptor between
containers) plus the full battery, for any image. The false "verified … in CI" claim in `README.md` and the
`docker/smoke` references in `docs/DEPLOYMENT.md` and `docs/HOTCELL-SPEC.md` are corrected in the same pass.

`docker/Gemfile` stays: it is the cell's own Gemfile, copied into the base image by the `Dockerfile`.

## Settled

1. `examples/operations` + `examples/lib` (the client classes and the shared battery live here).
2. The development-configuration check is a **rake task** (`rake test:devcell`), added to the default task — not a
   `bin/smoke` script — and it runs in CI on Linux and macOS.
3. `bin/conformance` is container-focused (launch an image, verify startup, the `HOTCELL_DIR` contract, the
   battery, and isolation) and **runs in CI on Linux**.
4. Consumers drive through the thin client classes, not a raw `Connection`.
5. `bin/load` is a script; heavy runs manual, a bounded run may gate CI later.
6. Drop the whole `docker/` directory and fix the stale references.
