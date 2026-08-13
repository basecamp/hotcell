# Tuning a cell

[docs/DEPLOYMENT.md](DEPLOYMENT.md) lists every setting and what it does. This is how to arrive at the
numbers for your own workload.

The short version: ship the defaults, instrument first, and tighten in one direction only.

## Instrument before you tune

You cannot tune what you cannot see, and two signals are independent of each other. Get both in before you
change any number.

**The `perform.hot_cell` notification.** It fires on every call, success or failure, and carries the
operation, the cell, the failure `code`, `bytes_in`, `bytes_out`, `perform_ms` and the full timing. It is
the only signal that survives a dead cell — an unreachable socket arrives here as `unavailable`, so the
primary alarm belongs on this and not on the cell's own metrics.

**The cell's `metrics`, on its control socket.** Poll it on a schedule. It answers while the work socket is
saturated, and it is host-local, so the poller has to be a process on the cell's own host. It reports
`running`, `queued`, `queue_high_water`, `cancelled`, the request counts by code, and `killed_by` broken
down by cause.

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

### Why those two are different

A permanent verdict is only irreversible if the application writes it down. In the shipped Active Storage
integration, analysis does and nothing else does.

Rails persists a blob's analysis like this:

```ruby
# ActiveStorage::Blob::Analyzable
def analyze
  update! metadata: metadata.merge(extract_metadata_via_analyzer)
end

def extract_metadata_via_analyzer
  analyzer.metadata.merge(analyzed: true)
end
```

`analyzed: true` is merged whatever the analyzer returned, including an empty hash. Rails never asks
whether the analysis worked. So the chain is:

1. The blob is attached. Rails enqueues `ActiveStorage::AnalyzeJob`, once.
2. The analyzer calls the cell and gets `killed: memory`, which the client raises as the application's
   permanent class.
3. `Analyzers::Analyzing#metadata` rescues that class, logs it, and returns `{}`.
4. Rails merges `analyzed: true` and writes the row.

The blob's `metadata` is now `{"identified"=>true, "analyzed"=>true}` — analyzed, with no dimensions.
Nothing re-enqueues the job, because `analyze_later` runs once at first attachment.

A transient failure is not rescued at step 3. It escapes into the job, which retries it, and `analyzed`
stays false.

Undoing a permanent one is a backfill:

```ruby
blob.update!(metadata: blob.metadata.except("analyzed"))
blob.analyze_later
```

**Previews and variants write no durable failure record.** `Preview#processed?` is `image.attached?`, and a
variant is recorded by its `active_storage_variant_records` row. A failure attaches nothing and creates
nothing, so the job simply retries. Only analysis needs the generous-first treatment.

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

## What to watch

| Signal | What it means |
| --- | --- |
| `killed_by` by cause | the only legitimate reason to tighten a limit |
| `queued_ms` p95 rising, `perform_ms` p95 flat | the cell needs more workers, not faster ones |
| `perform_ms` p95 rising | the work got more expensive; check for a library upgrade |
| `queue_high_water` near `queue_size` | no headroom left |
| `capacity` above zero in steady state | under-provisioned |
| `unavailable` | the cell is down, restarting, or unreachable |
| `unreadable` rate | worth watching after a toolchain upgrade |
| `worker.crashed` in the log | should be zero; anything else is a bug worth reporting |

## Where `bin/load` fits

`bin/load` answers one question: does the queue behave the way you configured it? It shows that
`queue_size` and `queue_wait` produce `capacity` where you expect, and it finds the knee for a known
service time.

It cannot give you your own numbers. It drives the example operations rather than yours, and it fixes the
container flags. Treat it as a check on the scheduling, not as a capacity plan.

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
