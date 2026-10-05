---
type: Reference
title: "Tuning"
order: 9
description: "Which measurement sets each cell number, the constraints between the numbers, and how to use bin/load."
sources:
  - hotcell-server/lib/hot_cell/configuration.rb
  - hotcell-client/lib/hot_cell/cell.rb
  - bin/load
  - examples/load
---

# Tuning

This page describes how to choose a cell's numbers for your workload: which measurement sets each one,
the constraints between them, and the order in which to change them. For what each setting does, see
[Cell settings](cell-settings.md) and [Container](container.md).

In short: ship the defaults, instrument first, and tighten in one direction only.

## Instrument before you tune

Before you change any number, collect both of the following signals. They're independent of each other.

- The `perform.hot_cell` notification, from the application. See
  [Per-call notification](observability.md#per-call-notification).
- The cell's `metrics`, from its control socket. See [Cell metrics](observability.md#cell-metrics).

For which signal means what, see [What to watch](observability.md#what-to-watch).

## Which measurement sets each number

| Setting | Where the number comes from |
| --- | --- |
| `memory` | One worker's peak on your largest real inputs. |
| `file_size` | The largest thing that one operation writes, plus any input that it stages. |
| `deadline` | The tail of `perform_ms` on real traffic. |
| `concurrency` | A load test, against `cpus`. |
| `queue_size`, `queue_wait` | A load test, against what the caller can wait for. |
| Container `memory`, `cpus`, tmpfs size | `concurrency` times the above. |

Only the scheduling numbers need contention to measure. The rest come from single requests, and a load
test tells you nothing useful about them.

## Start generous on `memory` and `file_size`

`memory` and `file_size` are the limits where a wrong value is expensive to undo:

- **A limit that's too high costs headroom.** The container's own memory limit still bounds the cell.
- **A limit that's too low kills a legitimate file.** The cell answers `killed` with cause `memory` or
  `fsize`. Both verdicts are permanent, so the caller is entitled to record them, and the shipped Active
  Storage analyzers do. See [What Active Storage records](codes.md#what-active-storage-records).

The two mistakes aren't equal, so use this order:

1. Set `memory` and `file_size` to the defaults.
2. Run real traffic for at least a week.
3. Read the peak that your operations reach.
4. Lower each limit to a value above that peak.

Don't use the opposite order: don't set a low limit and raise it when files fail. Every failure in that
period is a durable record against a customer's file.

Step 3 has a gap. The cell's metrics report `killed_by`, which counts failures. A count of zero tells you
that the limit is high enough, and doesn't tell you how much room is left. To find the room, measure the
operation outside the cell: run it on your largest inputs and read its peak.

`deadline` needs none of this care. A `deadline` kill is transient, so a value that's too low costs a
retry.

## Make the timeouts agree

The defaults don't agree with each other, and this is the first thing that you'll hit.

A cell reports `answer_within`, which is `queue_wait + deadline + 1`. On the defaults, that's 71 seconds.
The client's default `timeout` is 30 seconds.

When the client's `timeout` is below `answer_within`, a saturated cell reaches the caller as a transport
failure instead of as `capacity` or `killed`. That loses exactly the signal that you need to size
anything. The client warns at boot when its timeout doesn't clear the cell's number, and `describe`
reports `answer_within`.

Which way to fix it depends on the caller:

- **A background job** wants a loose timeout, above `answer_within`, so that it receives the cell's
  verdict and can act on it. Active Storage's analysis, preview, and variant work all runs in jobs.
- **A synchronous request** wants the opposite: a short `deadline` on the cell and a tight timeout on the
  client, because a thread held for a minute is a thread that isn't serving traffic.

Both outcomes are transient, so neither choice misclassifies anything. That's the only reason that this
is safe to decide for each caller.

## Constraints between the numbers

Nothing checks these constraints for you, except where noted.

- The client's `timeout` must be more than the cell's `answer_within`. See
  [Make the timeouts agree](#make-the-timeouts-agree). The client warns at boot.
- The cell's `memory` must be less than the container's `memory`. At equal values, the cgroup fires first,
  and a cgroup kill is a `SIGKILL` with no diagnostic.
- `file_size × concurrency` must be no more than the scratch. Above it, concurrent workers fill the
  scratch, and requests fail with `ENOSPC` instead of with a limit verdict. On the default accessory, the
  scratch is the tmpfs, and its `size=` is the number to fit. See [Scratch](scratch.md#what-changes-in-the-numbers).
- `concurrency × (MAGICK_DISK_LIMIT + everything else that one worker writes on scratch)` must be no more
  than the scratch. Above it, concurrent ImageMagick processes fill the scratch before any of them refuses
  a frame. `file_size` can't prevent that, because it bounds each cache file and not their sum. See
  [ImageMagick](imagemagick.md).
- `pids-limit` must clear `concurrency` plus the threads and subprocesses that one toolchain starts.

## Size against the container

These numbers are arithmetic against the container flags. For the README's accessory (`cpus: 2`,
`memory: 2g`, `size=512m`):

- `concurrency: 4`, because a request spends much of its life off the CPU, so twice `cpus` is where to
  start.
- `file_size: 48MB`, because that bounds what one worker writes.
- `memory: 1536MB`, because that's the measured working value for `RLIMIT_DATA`.

Size the cell to its most demanding operation. The cell clamps each operation's own `limits` to its own,
so the cell's numbers only ever take away. Read the `limits` that each operation you carry declares, and
set the cell above the highest of them. The shipped video previewer asks for `deadline: 120` and
`file_size: 128MB`. A cell configured with 30 seconds and 48MB kills every video preview and nothing else,
which is a hard failure to place. See [Active Storage operations](active-storage.md#limits).

### Sizing guidelines

- **`memory` doesn't multiply by `concurrency`.** It's an address-space charge on one worker. About 620MB
  of it is reserved and never touched, and about 450MB of that is Ruby's own reservation, which
  `RLIMIT_DATA` charges in full. Subtract 450MB before you read `memory` as the amount that an input can
  consume. The cgroup limit is what bounds real memory across the cell. See
  [experiments 11 and 12](development/experiments.md).
- **An input is charged only when an operation asks for its path.** A descriptor that an operation reads in
  place costs no tmpfs and no `file_size`, so a multi-gigabyte upload can be analyzed under a small
  `file_size`. An operation that needs a filename copies the input onto scratch first, and the kernel
  charges that copy exactly as it charges an output. Size `file_size` from the largest thing that your
  operations write, and count a staged input as one of them.
- **A large supervisor makes every request slower.** A worker's fixed cost is copy-on-write settling, and
  it's proportional to the supervisor's resident heap. A `before_fork` that requires more than the cell's
  own operations need is paid on every request for the life of the deployment. See
  [Cell overhead](development/overhead.md).

## Check the queue with `bin/load`

`bin/load` answers one question: does the queue behave the way that you configured it? It shows that
`queue_size` and `queue_wait` produce `capacity` where you expect, and it finds the knee for a known
service time.

```
bin/load IMAGE [SCENARIO] [SECONDS] [THREADS]
```

It runs a cell in a container and drives it from a second container. It reports throughput, the verdict
breakdown, and latency split into time queued and time performing. That split separates saturation from
slowness: queued time that grows while perform time stays flat means that the cell needs more workers.

It can't give you your own numbers. It drives the example operations rather than yours, and it fixes
`cpus`, `memory`, the tmpfs size, and `pids-limit`. Only the cell settings vary, through the following
environment variables:

- `EXAMPLE_CONCURRENCY`
- `EXAMPLE_QUEUE_SIZE`
- `EXAMPLE_QUEUE_WAIT`
- `EXAMPLE_DEADLINE`
- `EXAMPLE_MEMORY_MB`
- `EXAMPLE_FILE_SIZE_MB`

Treat it as a check on the scheduling, not as a capacity plan.

## A starting point

Deploy the documented defaults unchanged, with `max_requests_per_worker: 1`. Raise the client's timeout
above `answer_within` for any job path. Then let it run for a week and read the signals in
[What to watch](observability.md#what-to-watch).

`max_requests_per_worker: 1` is the right default to start from, because it's the isolating one. Raise it
only with a measurement that says the copy-on-write cost matters for your workload, and read
[ADR 0001](../adr/0001-reuse-workers-across-requests.md) first: it costs an isolation property, not just
memory.

## Don't tune against staging

A cell's behavior depends on the files that it's given. A staging or beta destination with synthetic
uploads won't predict production. The measurements that matter here were all taken on the deployed image
for that reason. See [ADR 0001](../adr/0001-reuse-workers-across-requests.md).

Tune against production traffic with generous limits. That direction fails slow rather than failing
closed.
