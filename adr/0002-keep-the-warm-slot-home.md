# 0002. Keep the warm slot home, as an accepted trade-off

- Status: Superseded by [ADR 0003](0003-remove-the-persistent-slot-home.md)
- Date: 2026-08-11
- Deciders: Mike Dalessio

## Context

Every worker runs in a numbered slot, and a slot has two directories. `scratch` holds one request's staged
files and is removed after every request. `home` becomes the worker's `$HOME`, is created once at boot, and
is removed by nothing.

Because nothing removes it, `home` survives across worker processes on the same slot number, not only across
the requests one worker serves. The review of `Supervisor` and `Worker` read that as a cross-request
poisoning channel: one request can write a file into the slot's home, and a later request on that slot reads
it.

The channel is real, and [ADR 0001](0001-reuse-workers-across-requests.md) already records that it is a
property of the slot rather than of worker reuse — three successive workers on one slot each read what the
previous process left, at `max_requests_per_worker: 1`. So the exposure exists at the isolating default, and
this decision is separate from the reuse decision.

### What the surviving home buys

Some tools keep state under `$HOME` and cannot share it between concurrent instances. LibreOffice keeps a
user profile there and corrupts itself when two instances use one, and building that profile is the tool's
cold start. A surviving per-slot home gives each slot its own profile, built once and warm afterwards, with
no warming pass and nothing spawned by the supervisor.

### What it costs

Two requests on one slot are not fully isolated from each other. The isolation that holds:

- Scratch is per-request and removed, so a request's own input and output bytes do not leak to the next
  request through the slot.
- The slot's home is private to the slot, so the leak is within one slot, never across slots or across
  cells.

The isolation that does not hold: whatever a tool chooses to persist under `$HOME` outlives the request that
wrote it. The exposure is a write rather than a read. For LibreOffice the user layer composes last, so a
malicious input that writes into the profile can disable the tool's own hardening for every later request on
that slot.

### Options considered

1. Keep the warm home, and document the exposure as a trade-off.
2. Reset the home before every request. Closes the channel. Pays the tool's profile cold start on every
   request, and the cost of a LibreOffice cold start is asserted in the code rather than measured.
3. Make it a per-operation choice — a warm home for operations that ask for one, a fresh home otherwise.
   The most flexible, and it adds a declaration to the operation surface and a second cleanup path.

## Decision

Take option 1. Keep the warm slot home, and document the cross-request exposure as a trade-off we accept.

This is not framed as an invariant that nothing sensitive may live in a tool's home. It is a trade-off:
the warm home is worth more than the exposure costs, given that the exposure is a within-slot write channel
and that nothing sensitive is expected in a tool's working home.

If we need to revisit this, option 3 is the fallback we will implement: a per-operation choice between a
warm home and a fresh one. It keeps the profile warmth for the operations that need it — LibreOffice — and
closes the channel for the operations that do not, rather than paying option 2's cold start on every
request across the board. That change supersedes this record.

## Consequences

- The slot's home is a persistence surface an operation author should treat as shared across requests on
  that slot. Nothing sensitive belongs there.
- The named fallback is option 3, a per-operation warm-or-fresh home. Revisiting this is a code change plus
  a superseding ADR, not a change of principle that has to be relitigated from scratch.
- Before choosing the fallback, measure a LibreOffice profile cold start. The code calls it expensive; that
  number is not yet measured, and it is what sets the fresh-home cost for the operations that opt out.
- The exposure is bounded to one slot. It is never a channel between slots, between cells, or to the
  application.
