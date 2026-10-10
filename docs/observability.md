---
type: Reference
title: "Observability"
order: 10
description: "Recommended alerts, the perform.hot_cell notification, the application log line, Yabeda metrics, cell metrics, the cell log schema, and the healthchecks."
sources:
  - hotcell-server/lib/hot_cell/log.rb
  - hotcell-server/lib/hot_cell/counters.rb
  - hotcell-server/lib/hot_cell/control.rb
  - hotcell-server/lib/hot_cell/health_operations.rb
  - hotcell-server/exe/hotcell-health
  - hotcell-client/lib/hot_cell/client.rb
  - hotcell-client/lib/hot_cell/log_subscriber.rb
  - hotcell-client/lib/hot_cell/health_controller.rb
  - hotcell-client/lib/hot_cell/diagnostics_controller.rb
  - yabeda-hotcell/lib
---

# Observability

This page describes the signals that Hot Cell produces and the alerts to set on them. The signals are as
follows:

- The `perform.hot_cell` notification, which the application publishes for each call.
- The application log line that `HotCell::LogSubscriber` writes for each call.
- The metrics that `yabeda-hotcell` records.
- The counters that a cell reports on its control socket.
- The cell's own log.
- The container and Rails healthchecks.

For which signal sets which limit, see [Tuning](tuning.md).

## Recommended alerts

- **Cell availability.** Alert when the `up` gauge is 0 or absent for any cell on any host. It reads 0
  first when a deploy missed a role, when the application lacks the cell's group, or when the supervisor is
  dead. On a host without `HOTCELL_ROOT`, the gauge is absent. Calls on that host raise
  `HotCell::CellNotConfigured`.
- **Failed calls.** Alert on the `requests` counter by `code`. The application records `unavailable`
  when the cell is down, restarting, or unreachable. Any shift away from `ok` is an early warning. Put the
  primary alarm on this signal rather than on the cell's own metrics, because the application records it
  even when the cell is dead.
- **Queue headroom.** Alert when `queued` nears the cell's `queue_size`, when `queue_high_water` rises
  toward it, or when `capacity` appears in steady state. Each means that the cell is under-provisioned.
  `queue_size` is configuration, not a metric. `queue_high_water` resets only at boot, so alert on its
  rise. A rising `cancelled` means that callers gave up waiting.
- **Scratch space.** Alert on free space on each host's scratch. For a disk-backed scratch, use
  `node_filesystem_avail_bytes` from the node exporter. For a tmpfs, compare the container's memory usage
  with the tmpfs `size=`. A full scratch fails every request that needs it. A write that fails inside
  libvips gets `unreadable` from the cell, a permanent failure against the file (see
  [ImageMagick](imagemagick.md#how-the-limits-interact-in-a-cell)). [Scratch](scratch.md) covers the
  layouts.
- **Cell errors.** Alert on any `ERROR` event in the cell log, such as `worker.crashed` or
  `worker.unforkable`, which should never happen. Alert on a rise in the `killed` gauge by cause. A single
  kill for `memory` or `fsize` is the cell rejecting a hostile file.

## What to watch

| Signal | What it means |
| --- | --- |
| `killed_by` by cause | The only legitimate reason to tighten a limit. |
| `queued_ms` p95 rising, `perform_ms` p95 flat | The cell needs more workers, not faster ones. |
| `perform_ms` p95 rising | The work got more expensive. Check for a library upgrade. |
| `queued` near `queue_size`, or `queue_high_water` rising toward it | No headroom is left. `queue_high_water` resets only at boot. |
| `capacity` above zero in steady state | The cell is under-provisioned. |
| `unavailable` | The cell is down, restarting, or unreachable. |
| `unreadable` rate | Worth watching after a toolchain upgrade. |
| `worker.crashed` in the log | Should be zero. Anything else is a bug worth reporting. |

## Per-call notification

The client publishes the `perform.hot_cell` Active Support notification for every call, whether it
succeeds or fails. It's the only signal that survives a dead cell: an unreachable socket arrives here as
`unavailable`. `HotCell::LogSubscriber` and `yabeda-hotcell` subscribe to it. To record anything else,
subscribe to it yourself.

The payload has the following keys:

| Key | Description |
| --- | --- |
| `operation` | The routing name. |
| `cell` | The registered cell name. |
| `code` | `ok` on success, the failure's code on failure, or `interrupted` when an exception interrupted the call, such as the application's own request timeout. |
| `cause` | The cause of a `killed` failure. |
| `signal` | The signal that ended the worker, if any. |
| `stderr` | The tail of what a dying worker wrote to file descriptor 2. Write it to a log field and nowhere else: a tool wrote it while it processed a hostile file. |
| `permanent` | Whether the failure is permanent. `nil` on success. |
| `bytes_in`, `bytes_out` | The total size of the inputs and of the outputs. `nil` when the client couldn't measure them, which isn't the same as zero. |
| `perform_ms` | Time that the cell spent in `perform`. |
| `timing` | Every timing that the cell reported, such as `queued_ms` and `perform_ms`. |

Classify failures by `permanent`, not by `code`. A `killed` failure is permanent for `fsize` and `memory`,
and transient for `deadline` and `crashed`, so the code alone can't say which side of the split a kill is
on. `permanent` is the cell's own answer, and `cause` is the reason. See [Response codes](codes.md).

A subscriber's own duration minus `perform_ms` is transport plus queueing. Track the two separately: a
rising `perform_ms` means that the work got more expensive, and a rising difference means that the cell is
saturated.

## Application logs

In a Rails application, `HotCell::LogSubscriber` writes one `info` line for each call to the Rails log:

```
  HotCell (41.2ms) {"cell":"images","operation":"active_storage.transformers.image.vips","code":"ok","perform_ms":38,"duration_ms":41.2,"bytes_in":20480,"bytes_out":8192}
```

For a failed call, the line adds `cause` and `stderr` when they exist. For a call that an exception
interrupted, the code is `interrupted` and the line adds the exception's class.

To turn the line off, call `HotCell::LogSubscriber.detach_from :hot_cell` in an initializer.

To use the line without Rails, do the following:

1. Require `hot_cell/log_subscriber`.
2. Call `HotCell::LogSubscriber.attach_to :hot_cell`.
3. Set `ActiveSupport::LogSubscriber.logger`.

## Metrics

The `yabeda-hotcell` gem records Hot Cell metrics in [Yabeda](https://github.com/yabeda-rb/yabeda). To
install it, add the gem to the application's `Gemfile` and call `Yabeda::HotCell.install!` once at boot:

```ruby
# Gemfile
gem "yabeda-hotcell"

# config/initializers/hotcell.rb
Yabeda::HotCell.install!
```

The metrics are in the `hotcell` group:

| Metric | Type | Tags | Description |
| --- | --- | --- | --- |
| `requests` | counter | `cell`, `operation`, `code`, `cause` | Each call, by the event's `code`. `cause` is empty when there's none. |
| `perform` | histogram | `cell`, `operation` | Seconds that the cell spent in `perform`. A call with no `perform_ms`, such as `capacity`, `unavailable`, `timeout` or `interrupted`, records nothing. |
| `up` | gauge | `cell` | 1 when the local cell answers its control socket, otherwise 0. |
| `running` | gauge | `cell` | Workers busy right now. |
| `queued` | gauge | `cell` | Connections waiting for a worker. |
| `queue_high_water` | gauge | `cell` | The deepest that the queue has been since boot. |
| `cancelled` | gauge | `cell` | Callers that gave up before the cell answered. This is a floor. |
| `killed` | gauge | `cell`, `cause` | Workers killed since boot, by cause. |
| `uptime_seconds` | gauge | `cell` | Seconds since the supervisor booted. |

On each scrape, the gem reads `metrics` from each registered cell and sets the gauges from it. A scrape
never fails because a cell misbehaves: the gem reports the error to the Active Support error reporter.

## Cell metrics

A cell answers `metrics` on its control socket. It answers even when the work socket is saturated. The
control socket is local to its host, so the process that polls it must run on the cell's host.

`metrics` reports `running`, `queued`, `queue_high_water`, `cancelled`, request counts by code, and
`killed_by`, broken down by cause.

`killed_by` counts what workers reported, not what the supervisor observed. A worker decides its own
`memory` and `fsize` failures, because the supervisor can't tell either from a wait status without
believing a signal that a sibling could have sent. The worker reports the cause when it reports itself
idle. As a result:

- The count arrives just after the caller has its answer, rather than before.
- The count is lost if the worker dies between the answer and the report.
- A compromised worker can report a cause that its request never had.

Size limits from `killed_by`. Don't read it as evidence about any particular document.

## Cell log

The cell writes one JSON object for each event to standard output, so whatever ships your container logs
ships these too.

Field names follow [ECS](https://www.elastic.co/guide/en/ecs/current/index.html), the schema that the
rest of the fleet's structured logs use. Every field that ECS has no name for is in the `hotcell`
namespace, so no future ECS field can collide with a Hot Cell field.

### Envelope

Every line carries these fields:

| Field | Type | Description |
| --- | --- | --- |
| `@timestamp` | string | When the event happened. UTC, ISO 8601, millisecond precision. |
| `service.name` | string | Always `"hotcell"`. This is the routing key: the log collector selects Hot Cell lines by it. |
| `event.action` | string | Which event this is. See [Events](#events). |
| `log.level` | string | `"INFO"`, `"WARN"`, or `"ERROR"`. The cell decides severity, not the collector, so adding an event never requires a collector change. |
| `process.pid` | integer | The process that the event is about: the worker's pid for `worker.*` events, the supervisor's own for `cell.*` events. Absent where no process is the subject. |

**Caution:** The fleet's log collector routes on `service.name == "hotcell"`, sets the record timestamp
from `@timestamp`, and takes severity from `log.level`. Renaming any of these three fields silently drops
or mislabels every cell log line in production. The rest of the schema can change.

### Shared fields

Where ECS has a name, the cell uses it:

| Field | Type | Used by |
| --- | --- | --- |
| `error.type` | string | The exception class name, wherever an exception is reported. |
| `error.message` | string | The sanitized exception message, beside `error.type`. |
| `message` | string | Prose detail, on events whose meaning needs it (`cell.ptrace_scope_unknown`, `slot.uncleaned`, `worker.unreadable_report`). |
| `event.outcome` | string | `"success"` or `"failure"`, on `request` only. |
| `event.duration.ms` | number | Wall time of the thing that ended. This is the fleet's dialect (Rails logs use `event.duration.ms`), not stock ECS (`event.duration` in nanoseconds). |
| `process.exit_code` | integer | The worker's exit status, on `worker.reaped`. |

### Hot Cell fields

Every other field is in the `hotcell` namespace:

| Field | Type | Description |
| --- | --- | --- |
| `hotcell.slot` | integer | The slot number. On nearly every event. |
| `hotcell.op` | string | The operation that the line is about, on `request`, `request.abandoned`, `worker.crashed`, `worker.killed`, and `worker.undispatchable`. `null` where the name wasn't known: a request that never parsed, a crash between requests, or a worker that died before it reported. Never the name of an earlier request. See [Which operation a line is about](#which-operation-a-line-is-about). |
| `hotcell.code` | string | The response code of a `request` (`"ok"`, `"failed"`, `"killed"`, and so on). |
| `hotcell.permanent` | boolean | Whether a `request` failure is permanent. |
| `hotcell.cause` | string | Why a worker was killed (`"deadline"`, `"memory"`, `"fsize"`, and so on). |
| `hotcell.signal` | string | The signal name (`"SIGKILL"`, `"SIGSEGV"`, and so on). ECS has no field for signals. |
| `hotcell.served` | integer | Requests that a worker served before it was reaped. |
| `hotcell.swept` | integer | Discarded trees that a sweeper found cleared, on `scratch.swept`: unlinked by it, or already gone when it reached them. |
| `hotcell.home` | string | The scratch directory that a cleanup couldn't clear: a request's `$HOME` from a worker, or the slot directory from the supervisor. |
| `hotcell.directory` | string | The cell's working directory, on `cell.boot`. |
| `hotcell.operations` | array | The registered operation names, on `cell.boot`. |
| `hotcell.configuration` | object | The full configuration inventory, in the same shape as `hotcell.describe`, on `cell.boot`. |
| `hotcell.running`, `hotcell.queued` | integer | In-flight and queued requests, on `cell.stopping`. |
| `hotcell.timing` | object | A request's phase timings: `queued_ms`, `perform_ms`, and any other measured phases. |
| `hotcell.deadline_s`, `hotcell.grace_s`, `hotcell.waited_s` | number | The limit that was hit, on the event that reports hitting it. |
| `hotcell.path` | string | On `cell.ptrace_scope_unknown`, the file that the cell couldn't verify. On `scratch.unswept`, the scratch entry, or the scratch itself, that a boot couldn't remove. |
| `hotcell.stderr` | string | The tail of what a dying worker wrote to file descriptor 2, at most 512 bytes. On `worker.killed` only, and absent when the worker wrote nothing. See [What a worker wrote to fd 2](#what-a-worker-wrote-to-fd-2). |

### Events

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
| `sweeper.forked` | INFO | — |
| `sweeper.deadline` | WARN | `hotcell.deadline_s` |
| `sweeper.died` | WARN | `hotcell.signal`, `process.exit_code`. A sweeper that ended abnormally by anything but the deadline kill. |
| `sweeper.unforkable` | ERROR | `error.type`, `error.message` |
| `sweeper.crashed` | ERROR | `error.type`, `error.message` |
| `scratch.swept` | INFO | `hotcell.swept`, `event.duration.ms` |
| `control.abandoned` | WARN | `hotcell.waited_s` |
| `control.unanswerable` | WARN | `error.type`, `error.message` |
| `slot.uncleaned` | WARN | `hotcell.slot`, `hotcell.home`, `message`. Boot sweep only. |
| `slot.undiscarded` | WARN | `hotcell.slot`, `hotcell.home` |
| `slot.unswept` | WARN | `hotcell.slot`, `hotcell.home`. From the worker that answered on the slot, or from the sweeper. |
| `scratch.unswept` | WARN | `hotcell.path`, and `error.type` and `error.message` when the scratch itself couldn't be listed. |

### Examples

A request:

```json
{"@timestamp":"2026-08-14T21:05:28.252Z","service":{"name":"hotcell"},"event":{"action":"request","outcome":"success","duration":{"ms":9.6}},"log":{"level":"INFO"},"process":{"pid":83},"hotcell":{"slot":0,"op":"active_storage.transform_image","code":"ok","permanent":null,"timing":{"queued_ms":0.4,"perform_ms":0.52}}}
```

A crash:

```json
{"@timestamp":"2026-08-14T21:05:29.107Z","service":{"name":"hotcell"},"event":{"action":"worker.crashed"},"log":{"level":"ERROR"},"process":{"pid":83},"error":{"type":"NoMethodError","message":"undefined method 'blur' for nil"},"hotcell":{"slot":0,"op":"active_storage.transform_image"}}
```

### What a worker wrote to fd 2

A worker's file descriptor 2 is a pipe to the supervisor. The supervisor drains it as the worker runs and
attaches the tail to the `worker.killed` event that reports the worker's death. The same text is in the
failure that the caller receives, so an application logs `killed: crashed (libgomp: ...)` rather than a
bare `crashed`.

The field exists for the one death that nothing else in a cell can describe. `HotCell::Worker#run`
rescues `Exception`, so a worker that died with no `worker.crashed` line probably died without Ruby
raising at all: a C library called `exit()` and wrote why to fd 2. For example:

```
libgomp: Thread creation failed: Resource temporarily unavailable
```

**Caution:** The text isn't evidence. It doesn't establish who wrote it or which request it belongs to,
the same caveat that `hotcell.signal` and `hotcell.cause` carry. It comes from the one process in a cell
that runs untrusted code, over an unauthenticated channel:

- Everything that a worker spawned inherits fd 2, so a tool can write long after its request finished.
- A sibling worker can open `/proc/<pid>/fd/2` and write anything, because workers share a uid, and
  `kernel.yama.ptrace_scope` protects memory, not descriptors.

The supervisor clears the buffer at each dispatch, which keeps an old warning off an unrelated death in the
ordinary case. That isn't a boundary.

The capture is best effort, because fd 2 is non-blocking. A C library that writes to a full pipe gets
`EAGAIN` and loses the line, and a fatal handler can't retry: it writes once and calls `exit()`. That costs
nothing in the case that the field exists for, where libgomp's one short line meets an empty pipe. It
loses the fatal message from a decoder that already filled the pipe with warnings: then the field reports
the tail of those warnings instead. A blocking fd 2 was rejected, because a warning written from inside
libvips would then wait on the supervisor's scheduling, in a C call that Ruby can't interrupt, and that
wait is longest exactly when the host is under pressure.

Only a death is reported. A worker that warns and then answers normally leaves no field on any event. So a
tool that dies while its worker survives isn't described here. A cell's standard error doesn't reach the
container's log driver.

### Which operation a line is about

`hotcell.op` lets a cell's own logs answer "which operation did this?". A cell runs several operations at
once, and they don't share limits, so an unattributed `worker.killed` can't be acted on. Nothing else
supplies the name: the response carries no operation, and `hotcell_killed` is tagged with `cell` and
`cause` only.

The two processes learn the name differently, which is why it can be absent:

- A **worker** parses it from the request that it's serving. `request`, `request.abandoned`, and
  `worker.crashed` carry it from the moment the request parses until the worker goes back to waiting. A
  request that never parsed has no name, and neither does a crash between requests.
- The **supervisor** never reads a request that a worker will serve, because staying out of it is what
  lets the supervisor dispatch a connection whose descriptors are still queued on it. It learns the name
  from the worker's report, which the worker sends after the request parses and before it touches an
  untrusted byte. That lets `worker.killed` name an operation that the dead worker can't report. If the
  worker died first, the field is `null` rather than the last request's name.

The report comes from the one process here that runs untrusted code, so the supervisor bounds the name to
an operation that this cell registered. The bound is on the report and nowhere else: a `request` line
names whatever the caller asked for, including a name that no operation answers to, which is what
`unsupported` is about and is worth seeing. A worker doesn't send a name whose report wouldn't fit one
control line, so `worker.killed` goes unattributed rather than losing the narrowed deadline that shares
the line.

`worker.undispatchable` is the exception, and the one line where the supervisor reads a request: the
worker died between the fork and the dispatch write, so nothing else read the request. The supervisor
peeks rather than reads, so neither the bytes nor the caller's descriptors leave the connection. It never
waits, so a request that hasn't arrived leaves the field `null`.

## Container healthcheck

The installed `Dockerfile` sets `hotcell-health` as the Docker `HEALTHCHECK`. It probes the supervisor's
control socket from inside the container, where `network: none` doesn't apply. Healthy means that the
supervisor answers, not that a worker is free. If you use your own container, set this healthcheck too.

`HOTCELL_HEALTH_TIMEOUT` sets how many seconds `hotcell-health` waits for an answer before it reports
unhealthy. See [Cell settings](cell-settings.md#environment-variables).

## Rails healthcheck

`hotcell-client` defines two controllers, `HotCell::HealthController` and `HotCell::DiagnosticsController`,
and no routes for them. Add a route for each to the application's `config/routes.rb`.

- `HotCell::HealthController` asks each registered cell for `describe` and `metrics` over its control
  socket. It returns `OK` with a 200 when at least one cell is registered and every cell answers.
  Otherwise, it returns `FAIL` with a 503. These calls take no worker, so you can make the endpoint
  public, like `/up`.
- `HotCell::DiagnosticsController` returns the result of every check as JSON, with a 503 if any check
  fails. Along with `describe` and `metrics`, it sends `health.echo` and `health.reopen` over the work
  socket. Each round trip takes a worker. Put this endpoint behind authentication.

Of the cell's two sockets, only the work socket carries file descriptors. So `describe` and `metrics`
succeed even when the application can't use the work socket, and only the round trips test it. A cell
without the shared group passes `health.echo` and fails `health.reopen` with `EACCES`.

To serve the round trips, add `require "hot_cell/health_operations"` to one of the cell's operation files.
Without it, the cell answers `unsupported` for both operations.

To authenticate the diagnostics controller, set its superclass in an initializer, then add the routes:

```ruby
# config/initializers/hotcell.rb
HotCell.diagnostics_controller_parent = "Admin::BaseController"

# config/routes.rb
get "up/hotcell" => "hot_cell/health#show", as: :hotcell_health_check

constraints subdomain: "admin" do
  get "hotcell" => "hot_cell/diagnostics#show", as: :hotcell_diagnostics
end
```

If your authentication is a concern, subclass the controller instead:

```ruby
# app/controllers/hotcell_diagnostics_controller.rb
class HotcellDiagnosticsController < HotCell::DiagnosticsController
  include StaffOnly
end

# config/routes.rb
get "up/hotcell/diagnostics" => "hotcell_diagnostics#show"
```

From a console, `HotCell.diagnose(work: true).as_json` returns the same checks. See
[Client API](client-api.md#diagnose-cells).
