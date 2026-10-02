---
type: Reference
title: "Response codes"
description: "Every failure code and kill cause, whether each is permanent or transient, the exception classes the client raises, and what Active Storage records."
sources:
  - hotcell-core/lib/hot_cell/codes.rb
  - hotcell-core/lib/hot_cell/failure.rb
  - hotcell-client/lib/hot_cell/failures.rb
  - hotcell-server/lib/hot_cell/worker.rb
  - activestorage-hotcell-client/lib/active_storage/hot_cell/client/analyzers/analyzing.rb
---

# Response codes

Every failed call carries a code, and every code is permanent or transient. This page lists the codes, the
causes of `killed`, and how the Active Storage integration records a permanent failure.

The permanent or transient split is the only distinction that changes what a caller must do:

- **Permanent:** the same request fails the same way until the input or the code changes. A change in load
  or deployment doesn't fix it. A caller can record a permanent failure against the input, for example
  against an Active Storage blob, and serve it from a cache.
- **Transient:** the request might succeed on a retry. A caller must retry a transient failure and must
  never record it.

The definitions live in [`hotcell-core/lib/hot_cell/codes.rb`](../hotcell-core/lib/hot_cell/codes.rb).

## Codes

| Code | Split | Meaning |
| --- | --- | --- |
| `unreadable` | Permanent | The operation couldn't decode the input. The operation said so explicitly: it raised one of the classes that it declared with `unreadable`. |
| `invalid` | Permanent | The request is malformed, or a descriptor failed its access-mode check. |
| `failed` | Transient | The operation raised an exception that nothing classified. |
| `unsupported` | Transient | The cell doesn't carry the requested operation. |
| `protocol` | Transient | The two sides speak different protocol versions. It heals when the accessory reboots on an image with the application's protocol version. |
| `capacity` | Transient | The cell's queue is full, or a queued request waited longer than `queue_wait`. |
| `unavailable` | Transient | The client couldn't connect, or the connection closed with no response. The client also reports `unavailable` when a cell reports success and writes no bytes to a non-empty set of outputs. |
| `timeout` | Transient | The client's own `timeout` passed before the cell answered. |
| `killed` | Depends on the cause | The supervisor killed the worker, or the worker died. See [Causes of `killed`](#causes-of-killed). |

### Why `failed` is transient

`failed` is what an unclassified exception becomes, so it can't be permanent. A worker rescues
`StandardError` around the whole request and reports `failed`. `Errno::ENOSPC`, `EMFILE`, `EIO`, `ENOENT`,
and `ENOMEM` are all `StandardError`s. Each of the following raises inside staging or writeback and arrives
as `failed`:

- A shared tmpfs that concurrent requests filled.
- A full disk under the caller's own output.
- A descriptor table that load exhausted.
- A fork that can't get memory under host pressure.
- A tool that's missing during a broken deploy.

`ENOMEM` looks like the input's fault and isn't. When an input drives the worker past its own memory
limit, Ruby raises `NoMemoryError`, which the worker reports as `killed` with cause `memory`.

A permanent `failed` would record each of these against a customer's file forever, for a condition that
would succeed on a retry. Permanence must be claimed, never inferred from not knowing: an operation reports
`unreadable` for an input that it couldn't decode, and the protocol reports `invalid` for a caller that
broke its own contract.

The cost of this choice is that a broken operation is retried. The job's attempts bound that cost, the
`failed` rate shows it, and it's recoverable.

### Why `unsupported` is transient

A Kamal deploy doesn't update an accessory. An application that ships a client for a new operation before
anyone reboots the cell gets `unsupported` on every request until the reboot. Recording that window as
permanent condemns every blob uploaded during it, and only a hand-written backfill undoes it. Retrying a
caller's typo costs some work, and the refusal names the operation in the worker's message and in the
`unsupported` rate.

## Causes of `killed`

A `killed` failure carries a `cause`. The cause decides the split, because a caller can't otherwise tell a
decompression bomb from a slow afternoon.

| Cause | Split | Meaning |
| --- | --- | --- |
| `fsize` | Permanent | A write by the worker returned `EFBIG`: the request passed its `file_size` limit. |
| `memory` | Permanent | The worker caught `NoMemoryError`: the request passed its `memory` limit. |
| `deadline` | Transient | The request passed its `deadline`, and the supervisor killed the worker's process group. |
| `crashed` | Transient | The worker died without answering, for any other reason. |

Size and memory are properties of the input, so the same bytes fail again on an idle cell. A deadline is
as much a property of the load: a permanent `deadline` would condemn whatever was uploaded during a busy
hour.

`crashed` is the cell's own fault rather than the input's. A misconfigured cell crashes on every request,
so a permanent `crashed` would condemn everything uploaded during a broken deploy. A `crashed` failure
carries `signal` when a signal ended the worker, and `stderr` when the worker wrote to file descriptor 2.
See [What a worker wrote to fd 2](observability.md#what-a-worker-wrote-to-fd-2).

The supervisor never infers `memory` or `fsize` from a signal. A signal says how a process died, never
why. Apart from the `SIGKILL` that the supervisor sends for a deadline, every signal comes from somewhere
that the supervisor can't see: a cgroup out-of-memory kill chosen on aggregate pressure, or one worker
signalling another, which nothing prevents because workers share a uid. The worker that holds the request
decides `memory` and `fsize` itself.

## Unknown codes and causes

A code or cause that a client doesn't recognize isn't permanent:

- The `permanent` flag travels on the wire, set by the side that knows. A client that's older than a code
  still disposes of that code correctly.
- When the wire carries no boolean `permanent`, the client derives it. An unknown code is transient.
- An unknown `killed` cause is transient. Adding a kill reason to the supervisor without a row in
  `Codes::PERMANENT_BY_CAUSE` can't make it permanent.

Retrying something permanent costs some work. Recording something transient is irreversible.

**Caution:** A compromised cell can forge the split. The client believes a boolean `permanent` from the
wire, and a worker that stole `work.sock` can write any answer. See
[Worker isolation](design/worker-isolation.md).

## Exception classes

The client raises one exception class for permanent failures and another for transient ones. Set them
with the `permanent:` and `transient:` options of `HotCell.register`. See
[Client API](client-api.md#register-a-cell).

By default, the client raises `HotCell::PermanentFailure` and `HotCell::TransientFailure`. No application
rescues these classes already, so an unclassified failure surfaces as an error rather than as a silent
permanent mark. `transient:` must not descend from `permanent:`, because the inheritance graph is the
classification.

The exception's message is the failure's `code`, `cause`, error class, and message, joined with `: `, then
the `stderr` tail in parentheses when it exists. For example, `killed: crashed (libgomp: ...)`.

## What Active Storage records

A permanent verdict is irreversible only if the application records it. In the shipped Active Storage
integration, analysis records it and nothing else does.

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

Rails merges `analyzed: true` whatever the analyzer returned, including an empty hash, and never checks
whether the analysis worked. A permanent failure takes this path:

1. The blob is attached. Rails enqueues `ActiveStorage::AnalyzeJob` once.
2. The analyzer calls the cell and gets `killed` with cause `memory`. The client raises the application's
   permanent class.
3. `Analyzers::Analyzing#metadata` rescues that class, logs it, and returns `{}`.
4. Rails merges `analyzed: true` and writes the row.

The blob's `metadata` is now `{"identified"=>true, "analyzed"=>true}`: analyzed, with no dimensions.
Nothing enqueues the job again, because `analyze_later` runs once, at first attachment.

`Analyzers::Analyzing#metadata` doesn't rescue a transient failure. The failure escapes into the job, the
job retries, and `analyzed` stays false.

To undo a permanent failure, backfill the blob:

```ruby
blob.update!(metadata: blob.metadata.except("analyzed"))
blob.analyze_later
```

Previews and variants record no durable failure. `Preview#processed?` is `image.attached?`, and a variant
is recorded by its `active_storage_variant_records` row. A failure attaches nothing and creates nothing, so
the job retries. For this reason, only analysis needs the generous-first order in
[Tuning](tuning.md#start-generous-on-memory-and-file_size).
