# Log lines

The cell writes one JSON object per line to stdout. Field names follow
[ECS](https://www.elastic.co/guide/en/ecs/current/index.html), the schema the rest of the fleet's
structured logs already speak. Anything ECS has no name for lives under the `hotcell` namespace, so
no future ECS field can collide with ours.

## The envelope

Every line carries these five fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `@timestamp` | string | When it happened. UTC, ISO 8601, millisecond precision. |
| `service.name` | string | Always `"hotcell"`. This is the routing key: the log collector selects our lines by it. |
| `event.action` | string | Which event this is. The full list is below. |
| `log.level` | string | `"INFO"`, `"WARN"` or `"ERROR"`. The emitter decides severity, not the collector, so adding an event never requires a collector change. |
| `process.pid` | integer | The process the event is about: the worker's pid for `worker.*` events, the supervisor's own for `cell.*`. Absent where no process is the subject. |

## Shared fields

Where ECS has a name, we use it:

| Field | Type | Used by |
| --- | --- | --- |
| `error.type` | string | Exception class name, wherever an exception is reported. |
| `error.message` | string | The sanitized exception message beside `error.type`. |
| `message` | string | Human-readable detail on events whose meaning needs prose (`cell.ptrace_scope_unknown`, `slot.uncleaned`, `worker.unreadable_report`). |
| `event.outcome` | string | `"success"` or `"failure"`, on `request` only. |
| `event.duration.ms` | number | Wall time of the thing that ended. This is the fleet's dialect (rails logs use `event.duration.ms`), not stock ECS (`event.duration` in nanoseconds). |
| `process.exit_code` | integer | The worker's exit status, on `worker.reaped`. |

Everything else is ours and sits under `hotcell.*`:

| Field | Type | Meaning |
| --- | --- | --- |
| `hotcell.slot` | integer | The slot number. On nearly every event. |
| `hotcell.op` | string | The operation the line is about, on `request`, `request.abandoned`, `worker.crashed`, `worker.killed` and `worker.undispatchable`. `null` where the name was not known: a request that never parsed, a crash between requests, a worker that died before it reported. Never the name of an earlier request. |
| `hotcell.code` | string | The response code of a `request` (`"ok"`, `"failed"`, `"killed"`, ...). |
| `hotcell.permanent` | boolean | Whether a `request` failure is permanent. |
| `hotcell.cause` | string | Why a worker was killed (`"deadline"`, `"memory"`, `"fsize"`, ...). |
| `hotcell.signal` | string | Signal name (`"SIGKILL"`, `"SIGSEGV"`, ...). ECS has no field for signals. |
| `hotcell.served` | integer | Requests a worker served before it was reaped. |
| `hotcell.home` | string | The scratch directory a cleanup could not clear: a request's `$HOME` from a worker, the slot directory from the supervisor. |
| `hotcell.directory` | string | The cell's working directory, on `cell.boot`. |
| `hotcell.operations` | array | Registered operation names, on `cell.boot`. |
| `hotcell.configuration` | object | The full configuration inventory (same shape as `hotcell.describe`), on `cell.boot`. |
| `hotcell.running` / `hotcell.queued` | integer | In-flight and queued requests, on `cell.stopping`. |
| `hotcell.timing` | object | A request's phase timings: `queued_ms`, `perform_ms`, and any measured phases. |
| `hotcell.deadline_s` / `hotcell.grace_s` / `hotcell.waited_s` | number | The limit that was hit, on the event that reports hitting it. |
| `hotcell.path` | string | The file the cell could not verify, on `cell.ptrace_scope_unknown`. |
| `hotcell.stderr` | string | The tail of what a dying worker wrote to file descriptor 2, at most 512 bytes. On `worker.killed` only, and absent when it wrote nothing. See below. |

## Events

| `event.action` | `log.level` | Fields beyond the envelope |
| --- | --- | --- |
| `cell.boot` | INFO | `hotcell.directory`, `hotcell.operations`, `hotcell.configuration` |
| `cell.stopping` | INFO | `hotcell.running`, `hotcell.queued` |
| `cell.stopped` | INFO | — |
| `cell.ptrace_scope_unknown` | ERROR | `hotcell.path`, `message` |
| `request` | INFO | `hotcell.slot`, `hotcell.op`, `hotcell.code`, `hotcell.permanent`, `event.outcome`, `event.duration.ms`, `hotcell.timing` |
| `request.abandoned` | WARN | `hotcell.slot`, `hotcell.op` |
| `worker.forked` | INFO | `hotcell.slot` |
| `worker.reaped` | INFO | `hotcell.slot`, `hotcell.served`, `hotcell.signal`, `process.exit_code` |
| `worker.crashed` | ERROR | `hotcell.slot`, `hotcell.op`, `error.type`, `error.message` |
| `worker.killed` | WARN | `hotcell.slot`, `hotcell.op`, `hotcell.cause`, `hotcell.signal`, `event.duration.ms`, `hotcell.stderr` |
| `worker.deadline` | WARN | `hotcell.slot`, `hotcell.deadline_s` |
| `worker.lingered` | WARN | `hotcell.slot`, `hotcell.grace_s` |
| `worker.unforkable` | ERROR | `hotcell.slot`, `error.type`, `error.message` |
| `worker.undispatchable` | ERROR | `hotcell.slot`, `hotcell.op`, `error.type` |
| `worker.unreadable_report` | ERROR | `message` |
| `control.abandoned` | WARN | `hotcell.waited_s` |
| `control.unanswerable` | WARN | `error.type`, `error.message` |
| `slot.uncleaned` | WARN | `hotcell.slot`, `hotcell.home`, `message` (boot sweep only) |
| `slot.undiscarded` | WARN | `hotcell.slot`, `hotcell.home` |
| `slot.unswept` | WARN | `hotcell.slot`, `hotcell.home` |

## What a worker wrote to fd 2

A worker's fd 2 is a pipe to the supervisor, which drains it as the worker runs and attaches the tail to
the `worker.killed` reporting its death. The same text rides the failure the caller receives, so an
application logs `killed: crashed (libgomp: ...)` rather than a bare `crashed`.

It exists for the death nothing else in a cell can describe. `HotCell::Worker#run` rescues `Exception`, so
a worker that died with no `worker.crashed` line probably died without Ruby raising at all: a C library
called `exit()`, and said why on fd 2.

```
libgomp: Thread creation failed: Resource temporarily unavailable
```

**The text is not evidence — it establishes neither who wrote it nor which request it belongs to**, the
caveat `hotcell.signal` and `hotcell.cause` already carry. It comes from the one process in a cell that
runs untrusted code, over an unauthenticated channel: everything a worker spawned inherits fd 2, so a tool
can write long after the request it belongs to finished, and a sibling worker can open `/proc/<pid>/fd/2`
and write whatever it likes, since workers share a uid and `kernel.yama.ptrace_scope` protects memory
rather than descriptors. The supervisor clears the buffer at each dispatch, which keeps an old warning off
an unrelated death in the ordinary case. It is not a boundary.

**The capture is best effort, because fd 2 is non-blocking.** A C library writing to a full pipe gets `EAGAIN`
and loses the line, and a fatal handler cannot retry — it writes once and calls `exit()`. That costs nothing
in the case this exists for, where libgomp's one short line meets an empty pipe. What it loses is the fatal
from a decoder that had already filled the pipe with warnings, where the field reports the tail of those
warnings instead. The alternative was refused: a blocking fd 2 would make a warning written from inside
libvips wait on the supervisor's scheduling, in a C call Ruby cannot interrupt, and that wait is nearest
exactly when the host is under pressure.

**Only a death is reported.** A worker that warns and then answers normally leaves no field behind, on any
event. So a tool that dies while its worker survives is not described here, and a cell's stderr no longer
reaches the container's log driver at all — which loses nothing, because the fleet's OTel collector drops
complete non-JSON lines at ingest.

## Examples

A request:

```json
{"@timestamp":"2026-08-14T21:05:28.252Z","service":{"name":"hotcell"},"event":{"action":"request","outcome":"success","duration":{"ms":9.6}},"log":{"level":"INFO"},"process":{"pid":83},"hotcell":{"slot":0,"op":"active_storage.transform_image","code":"ok","permanent":null,"timing":{"queued_ms":0.4,"perform_ms":0.52}}}
```

A crash:

```json
{"@timestamp":"2026-08-14T21:05:29.107Z","service":{"name":"hotcell"},"event":{"action":"worker.crashed"},"log":{"level":"ERROR"},"process":{"pid":83},"error":{"type":"NoMethodError","message":"undefined method 'blur' for nil"},"hotcell":{"slot":0,"op":"active_storage.transform_image"}}
```

## Which operation a line is about

`hotcell.op` is what makes a cell's own logs answer "which operation did this?". A cell runs several
operations at once and they do not share limits, so a `worker.killed` naming none of them cannot be
acted on — and nothing else can supply the name either: the app-side response carries no operation, and
`hotcell_killed` is tagged `cell` and `cause` only.

The two sides learn it differently, which is why it can be absent.

A **worker** parses the name out of the request it is serving, so `request`, `request.abandoned` and
`worker.crashed` carry it from the moment the request parses until the worker goes back to waiting. A
request that never parsed has no name, and a crash between requests has none either.

The **supervisor** never reads a request — staying out of it is what lets it dispatch a connection whose
descriptors are still queued on it — so it learns the name from the worker's own report, sent once the
worker has parsed the request and before it touches an untrusted byte. That is why `worker.killed` can
name the operation at all: the worker is dead by the time that line is written. A worker that died before
reporting leaves `hotcell.op` null rather than borrowing the name of the request the slot served last.

Because it arrives from the one process here that runs untrusted code, a reported name is bounded to an
operation this cell registered before it is written down. That bound is on the worker's report and nowhere
else: a `request` line names whatever the caller asked for, including a name no operation answers to, which
is the case `unsupported` is about and the one worth seeing.

An operation name over 256 bytes is not reported at all, so the line is unattributed rather than the
narrowed deadline riding with it being lost. The two share one control line and the supervisor drops an
oversized report whole.

`worker.undispatchable` is the exception to all of that, and the one line where the supervisor reads a
request. The worker died between the fork and the dispatch write, so nothing has read the request and the
supervisor is the side that answers it. It peeks the line rather than reading it, so neither the bytes nor
the caller's descriptors leave the connection, and it never waits: a caller that has not sent yet, or a
line still arriving, leaves the field null.

## The contract with the collector

The fleet's log collector routes on `service.name == "hotcell"`, sets the record timestamp from
`@timestamp`, and takes severity from `log.level`. Those three fields are therefore load-bearing:
renaming any of them silently drops or mislabels every cell log line in production. The rest of the
schema can evolve freely.
