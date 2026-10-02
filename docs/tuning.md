# Tuning a cell

[docs/DEPLOYMENT.md](DEPLOYMENT.md) lists every setting and what it does. This is how to arrive at the
numbers for your own workload.

The short version: ship the defaults, instrument first, and tighten in one direction only.

## Which number comes from which measurement

| Setting | Where the number comes from |
| --- | --- |
| `memory` | one worker's peak on your largest real inputs |
| `file_size` | the largest thing one operation writes, plus any input it stages |
| `deadline` | the tail of `perform_ms` on real traffic |
| `concurrency` | a load test, against `cpus` |
| `queue_size`, `queue_wait` | a load test, against what the caller can wait for |
| container `memory`, `cpus`, tmpfs size | `concurrency` times the above |

Only the scheduling numbers need contention to measure. The rest come from single requests, and a load
test tells you nothing useful about them.

## Start generous on two of them

`memory` and `file_size` are the two where a wrong value is expensive to undo.

**A limit that is too high costs headroom.** The container's own memory limit still bounds the cell.

**A limit that is too low kills a legitimate file.** The cell answers `killed: memory` or `killed: fsize`.
Both verdicts are permanent, which means the caller is entitled to write them down — and one shipped path
does. See below.

The two mistakes are not equal, so use this order:

1. Set `memory` and `file_size` to the defaults.
2. Run real traffic for at least a week.
3. Read the peak your operations reach.
4. Lower each limit to a value above that peak.

Do not use the opposite order. Do not set a low limit and raise it when files fail. Every failure in that
period is a durable record against a customer's file.

One gap in step 3: the cell's metrics report `killed_by`, which counts failures. A count of zero tells you
the limit is high enough. It does not tell you how much room is left. To find the room, measure the
operation outside the cell — run it on your largest inputs and read its peak.

`deadline` needs none of this care. It is transient, so a value that is too low costs a retry.

## Make the timeouts agree

The defaults do not agree with each other, and this is the first thing you will hit.

A cell reports `answer_within`, which is `queue_wait + deadline + 1`. On the defaults that is **71
seconds**. The client's default `timeout` is **30 seconds**.

Under that, a saturated cell reaches the caller as a transport failure instead of as `capacity` or
`killed` — losing exactly the signal you need to size anything. The client warns at boot when its timeout
does not clear the cell's number.

Which way to fix it depends on the caller:

- **A background job** wants a loose timeout, above `answer_within`, so it receives the cell's verdict and
  can act on it. Active Storage's analysis, preview and variant work is all jobs.
- **A synchronous request** wants the opposite: a short `deadline` on the cell and a tight timeout on the
  client, because a thread held for a minute is a thread not serving traffic.

Both outcomes are transient, so neither choice misclassifies anything. That is the only reason this is
safe to decide per caller.

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

## Making the numbers agree

Nothing checks these for you.

- The client's `timeout` must be more than the cell's `answer_within`, which is
  `queue_wait + deadline + 1`. Below it, a saturated cell reaches the caller as a transport failure
  instead of as `capacity` or `killed`. The client warns at boot, and `describe` reports the number.
- The cell's `memory` must be less than the container's `memory`. At equal values the cgroup fires
  first, and a cgroup kill is a `SIGKILL` with no diagnostic.
- `file_size × concurrency` must be no more than the scratch. Above it, concurrent workers fill the
  scratch and requests fail with `ENOSPC` instead of with a limit verdict. On the default accessory the
  scratch is the tmpfs, and its `size=` is the number to fit.
- `concurrency × (MAGICK_DISK_LIMIT + everything else one worker writes on scratch)` must be no more
  than the scratch. Above it, concurrent ImageMagick processes fill the scratch before any of them
  refuses a frame, and `file_size` cannot prevent that, because it bounds each cache file and not their
  sum. See [docs/IMAGEMAGICK.md](IMAGEMAGICK.md).

Three things are fixed and cannot be configured: the one-second grace between the signal to a worker and
the kill of its process group, the absence of an `RLIMIT_CPU`, and the socket file mode.

## Where `bin/load` fits

`bin/load` answers one question: does the queue behave the way you configured it? It shows that
`queue_size` and `queue_wait` produce `capacity` where you expect, and it finds the knee for a known
service time.

```
bin/load IMAGE [SCENARIO] [SECONDS] [THREADS]
```

It runs a cell in a container and drives it from a second one. It reports throughput, the verdict
breakdown, and latency split into time queued against time performing. That split is what separates
saturation from slowness: queued time that grows while perform time stays flat means the cell needs more
workers.

It cannot give you your own numbers. It drives the example operations rather than yours, and it fixes
`cpus`, `memory`, the tmpfs size and `pids-limit` — only the cell settings vary, through
`EXAMPLE_CONCURRENCY`, `EXAMPLE_QUEUE_SIZE`, `EXAMPLE_QUEUE_WAIT`, `EXAMPLE_DEADLINE`, `EXAMPLE_MEMORY_MB`
and `EXAMPLE_FILE_SIZE_MB`. Treat it as a check on the scheduling, not as a capacity plan.

## A starting point

Deploy the documented defaults unchanged, with `max_requests_per_worker: 1`. Raise the client's timeout
above `answer_within` for any job path. Then let it run for a week and read the numbers above.

`max_requests_per_worker: 1` is the right default to start from because it is the isolating one. Raise it
only with a measurement that says the copy-on-write cost matters for your workload, and read
[ADR 0001](../adr/0001-reuse-workers-across-requests.md) first — it costs an isolation property, not just
memory.

## A caution about staging

A cell's behaviour is a function of the files it is given. A staging or beta destination with synthetic
uploads will not predict production, and the measurements that matter here were all taken on the deployed
image for that reason — see [ADR 0001](../adr/0001-reuse-workers-across-requests.md).

Tune against production traffic with generous limits. That direction fails slow rather than failing
closed.
