# 0001. A worker may serve more than one request, and serves one by default

- Status: Accepted
- Date: 2026-08-11
- Deciders: Mike Dalessio

## Context

A cell forks a worker per request. `max_requests_per_worker` lets one worker serve several before it is
discarded, and it defaults to `1`. An adversarial review of `Supervisor` and `Worker` proposed removing the
setting and fixing every worker at one request, on the grounds that reuse is the only thing in the design
that lets one request reach another inside a process.

That claim is correct. It is also the whole of what reuse costs, so the decision turns on what reuse buys.

### What reuse buys, measured

A worker's first request faults in the pages a real libvips pipeline needs, and its later requests do not.
For a 3000x2000 to 800x600 JPEG transform the first request charges 12,926 minor faults and later requests
charge 269. A reused worker's own first request charges 12,985 — the same as one-shot. Reuse amortizes that
one quantity and nothing else.

Measured in the deployed artifact rather than on a development machine, because the two disagree. The image
is `ruby:3.4-slim` with Debian's libvips 8.16 and ffmpeg, built from the `hotcell:install` Dockerfile
template with its example apt line filled in. `concurrency: 4`, error bands ±16% to ±20%.

| Workload | Callers | One-shot | Reused | Penalty |
| --- | --- | --- | --- | --- |
| libvips, 3000x2000 to 800x600 jpg | 1 | 66.97ms | 40.84ms | +26.1ms |
| libvips, 3000x2000 to 800x600 jpg | 4 | 91.89ms | 62.83ms | +29.1ms |
| libvips, 823B png thumbnail | 1 | 22.51ms | 5.73ms | +16.8ms |
| libvips, 823B png thumbnail | 4 | 25.22ms | 9.63ms | +15.6ms |
| ffmpeg, 720p 5s mp4 | 1 | 182.27ms | 167.68ms | +14.6ms, within error |
| ffmpeg, 720p 5s mp4 | 4 | 263.53ms | 237.41ms | +26.1ms |

The four-caller rows are per burst of four requests.

**Read the cost in milliseconds, not as a ratio.** The penalty is a roughly fixed quantity of page faults,
so the ratio falls as the real work grows. It is 1.5x for a full-size photo variant and 3.9x for a small
thumbnail, and both are the same +16 to +29ms. An operation that hands its bytes to a subprocess pays
almost nothing, because it initializes no library in its own address space.

### Mitigations tested and rejected

- `Process.warmup` before the first fork, as Rails does. No effect beyond the error band. It manages the
  Ruby object heap, and these pages are libvips' working set.
- A 1x1 `Vips::Image.black(1,1).avg` at worker boot. No effect. A 1x1 image touches almost none of the
  12,000 pages a real pipeline touches.
- Pre-forking would recover `fork` alone, which is 2.8ms of the penalty. The faults land inside `perform`.
- Transparent huge pages are already enabled on the hosts measured.

A cheaper lever exists and does not involve the worker lifecycle at all. The fault count scales with what
the supervisor maps, and requiring `image_processing/vips` maps 84.3MB across 136 files, including all five
libvips loader modules whether an operation uses them or not. Shrinking that is future work.

### What reuse costs

An exploited worker holds the descriptors of every request it is later given, so it can read and write
another caller's bytes. At `1` an exploited worker sees only the input that exploited it.

Two kernel-enforced limits stay unavailable while a worker may serve more than one request.

1. `RLIMIT_DATA` and `RLIMIT_FSIZE` keep their hard limit at the cell's ceiling rather than at the
   operation's value, so a reused worker can widen back for an operation with a different budget. Code
   running in the worker can therefore raise its own soft limit back to that ceiling.
2. `RLIMIT_CPU` is cumulative over a process's life, so it stops meaning "per request" as soon as a worker
   serves two. It is the only backstop that fires when the supervisor's own deadline logic is wrong.

An `idle` report from a worker also cannot be bounded. Under one request per worker, "claims to be idle" and
"must now exit" name the same moment, so the supervisor can time it. With reuse a legitimately idle worker
parks in `await_dispatch` indefinitely, and no timer distinguishes it from one that is lying.

### A justification that turned out to be false

The design documents credited reuse with keeping LibreOffice's profile warm. It does not. `Slot#home` is
created once at boot and removed by nothing, so it survives across worker processes on the same slot
number — three successive workers on slot 0 each read what the previous process left, at
`max_requests_per_worker: 1`. Profile warmth needs a stable slot, not a surviving worker.

That also means `1` does not isolate requests from each other completely. It isolates memory. A file
written into a slot's home is still readable by the next request on that slot.

## Decision

Keep `max_requests_per_worker`. The default stays `1`.

The penalty for one request per worker is +16 to +29ms on every in-process request, and about a third of
in-process throughput. That is too much to force on every application that deploys a cell, when the
application is the party that knows whether its cell is single-tenant and whether its operations hand work
to a subprocess.

## Consequences

- The default install isolates requests within a process. Raising the setting is a deliberate act by an
  operator, and the documentation must state what it gives up in those terms.
- The two rlimit hardenings above stay unavailable, and the soft limit stays the only one an operation
  narrows.
- The supervisor cannot enforce a bound between an `idle` report and a worker's exit. Any fix for a worker
  that reports idle and then does not exit has to work without that bound.
- `before_worker_boot` hooks must be re-entrant, because a worker can serve operation A, then B, then A.
  This is a standing requirement on operation authors.
- libvips' operation cache stays disabled, because above `1` it would hold one request's image data while
  the next one runs.
- The LibreOffice rationale must be corrected wherever it appears, and the claim that `1` is the only value
  where a request cannot reach another must be qualified to memory.
- Reuse buys nothing measurable for operations that run a tool in a subprocess. An operator raising the
  setting for such a cell is accepting the isolation cost for no gain.
