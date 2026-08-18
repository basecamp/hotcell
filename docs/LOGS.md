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
| `hotcell.code` | string | The response code of a `request` (`"ok"`, `"failed"`, `"killed"`, ...). |
| `hotcell.permanent` | boolean | Whether a `request` failure is permanent. |
| `hotcell.cause` | string | Why a worker was killed (`"deadline"`, `"memory"`, `"fsize"`, ...). |
| `hotcell.signal` | string | Signal name (`"SIGKILL"`, `"SIGSEGV"`, ...). ECS has no field for signals. |
| `hotcell.served` | integer | Requests a worker served before it was reaped. |
| `hotcell.home` | string | A slot's scratch directory. |
| `hotcell.directory` | string | The cell's working directory, on `cell.boot`. |
| `hotcell.operations` | array | Registered operation names, on `cell.boot`. |
| `hotcell.configuration` | object | The full configuration inventory (same shape as `hotcell.describe`), on `cell.boot`. |
| `hotcell.running` / `hotcell.queued` | integer | In-flight and queued requests, on `cell.stopping`. |
| `hotcell.timing` | object | A request's phase timings: `queued_ms`, `perform_ms`, and any measured phases. |
| `hotcell.deadline_s` / `hotcell.grace_s` / `hotcell.waited_s` | number | The limit that was hit, on the event that reports hitting it. |
| `hotcell.path` | string | The file the cell could not verify, on `cell.ptrace_scope_unknown`. |

## Events

| `event.action` | `log.level` | Fields beyond the envelope |
| --- | --- | --- |
| `cell.boot` | INFO | `hotcell.directory`, `hotcell.operations`, `hotcell.configuration` |
| `cell.stopping` | INFO | `hotcell.running`, `hotcell.queued` |
| `cell.stopped` | INFO | — |
| `cell.ptrace_scope_unknown` | ERROR | `hotcell.path`, `message` |
| `request` | INFO | `hotcell.slot`, `hotcell.code`, `hotcell.permanent`, `event.outcome`, `event.duration.ms`, `hotcell.timing` |
| `request.abandoned` | WARN | `hotcell.slot` |
| `worker.forked` | INFO | `hotcell.slot` |
| `worker.reaped` | INFO | `hotcell.slot`, `hotcell.served`, `hotcell.signal`, `process.exit_code` |
| `worker.crashed` | ERROR | `hotcell.slot`, `error.type`, `error.message` |
| `worker.killed` | WARN | `hotcell.slot`, `hotcell.cause`, `hotcell.signal`, `event.duration.ms` |
| `worker.deadline` | WARN | `hotcell.slot`, `hotcell.deadline_s` |
| `worker.lingered` | WARN | `hotcell.slot`, `hotcell.grace_s` |
| `worker.unforkable` | ERROR | `hotcell.slot`, `error.type`, `error.message` |
| `worker.undispatchable` | ERROR | `hotcell.slot`, `error.type` |
| `worker.unreadable_report` | ERROR | `message` |
| `control.abandoned` | WARN | `hotcell.waited_s` |
| `control.unanswerable` | WARN | `error.type`, `error.message` |
| `slot.uncleaned` | WARN | `hotcell.slot`, `hotcell.home`, `message` (boot sweep only) |
| `slot.undiscarded` | WARN | `hotcell.slot`, `hotcell.home` |

## Examples

A request:

```json
{"@timestamp":"2026-08-14T21:05:28.252Z","service":{"name":"hotcell"},"event":{"action":"request","outcome":"success","duration":{"ms":9.6}},"log":{"level":"INFO"},"process":{"pid":83},"hotcell":{"slot":0,"code":"ok","permanent":null,"timing":{"queued_ms":0.4,"perform_ms":0.52}}}
```

A crash:

```json
{"@timestamp":"2026-08-14T21:05:29.107Z","service":{"name":"hotcell"},"event":{"action":"worker.crashed"},"log":{"level":"ERROR"},"process":{"pid":83},"error":{"type":"NoMethodError","message":"undefined method 'blur' for nil"},"hotcell":{"slot":0}}
```

## The contract with the collector

The fleet's log collector routes on `service.name == "hotcell"`, sets the record timestamp from
`@timestamp`, and takes severity from `log.level`. Those three fields are therefore load-bearing:
renaming any of them silently drops or mislabels every cell log line in production. The rest of the
schema can evolve freely.
