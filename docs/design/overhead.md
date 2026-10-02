---
type: Design
title: "What the overhead measures at"
description: "Where the fixed cost of a call comes from, and the candidates that were ruled out."
---

# What the overhead measures at

Read this page for its negative results rather than its numbers. The numbers came off a laptop from a
prototype; the things that were ruled out are properties of the design. For the reuse trade specifically,
[ADR 0001](../../adr/0001-reuse-workers-across-requests.md) supersedes this with measurements taken in the
deployed artifact.

Three arms, each producing a 256×256 PNG with `resize_to_fill`: in process, a native cell over a Unix
socket, and a containerized cell with the hardening flags on. The cell arms ran 2.3×, 1.9×, and 1.7×
slower as the source grew from a 12KB JPEG to a 328KB one.

**The overhead is roughly fixed at 25 to 35 ms**, which is why the multiplier falls as the work grows.
Expect the ratio to look worst on the smallest thumbnails and to stop mattering on anything expensive.

Four candidates were tested and eliminated, recorded so nobody re-runs them:

| Candidate | Verdict |
| --- | --- |
| The container | Within noise of the native cell on two of three sources, 12ms on the largest. |
| The `fork` syscall | 2.8 ms of a 20–30 ms cost. |
| `RLIMIT_AS`, which the worker sets and the in-process arm does not | No effect. 8 GB, 2 GB, and unset are indistinguishable. |
| libvips thread pool startup per worker | Not it. The first-versus-second-call gap is *largest* at concurrency 1. |
| The libvips operation cache, as a confound favouring the in-process arm | Not it. `Vips.cache_set_max 0` moved that column by less than the error bars. |

**The overhead is copy-on-write, measured rather than inferred.** The identical pipeline runs about 14 ms
slower in a freshly forked worker than in a long-lived process. Run it *twice* in the same child and the
second call matches a warm process, so it is one cost per process, not per call. Minor fault counts say
what it is: **7,920 faults on a child's first call against 1,564 warm**, about 25 MB of pages copied at
roughly 1.7 µs each.

**So the cheapest optimisation is the counter-intuitive one: keep the supervisor small, and treat
`before_fork` as having a per-request price.** The instinct is to preload generously so workers start
fast. It is backwards here — every megabyte the supervisor holds is partly copied by every worker for the
rest of the deployment. `before_fork` must still `require`, because of the fork hazard in [experiment 1](experiments.md), so
the resolution is to require only what that cell's own operations need. That is a third argument for one
cell per toolchain, and a measured reason for `hotcell-server` not to depend on `activesupport`.

Do not spend effort making the container cheaper. There is nothing there to win.

**Synthetic pre-warming is not a free alternative to worker reuse.** Tested, because it would have been
the ideal answer: running a synthetic 64×64 pipeline in the worker before the real transform moved the
real transform's faults from 7,885 only to 6,184, against a warm floor of about 3,300 — roughly a quarter
of the excess. Most of the cost is proportional to the real image's own work, not to shared code paths a
synthetic image would touch.

Budget the fixed cost against inline processing. A variant generated during an upload request, as Active
Storage's `process: :immediately` does, adds this overhead to that request. Whether that is acceptable is
a product decision, and it is the main reason to measure it early on real hardware.
