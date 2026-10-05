---
type: Glossary
title: "Concepts"
order: 1
description: "The terms the Hot Cell documentation uses: cell, supervisor, worker, slot, operation, client, tool, payload, inputs and outputs, and codes."
sources:
  - hotcell-server/lib/hot_cell/supervisor.rb
  - hotcell-server/lib/hot_cell/worker.rb
  - hotcell-server/lib/hot_cell/slot.rb
  - hotcell-server/lib/hot_cell/operation.rb
  - hotcell-client/lib/hot_cell/client.rb
  - hotcell-core/lib/hot_cell/descriptors.rb
  - hotcell-core/lib/hot_cell/naming.rb
---

# Concepts

This page defines the terms that the rest of the Hot Cell documentation uses. The
[design overview](design/threat-model.md#what-this-is) explains the "hot" and "cold" vocabulary.

## Cell

A cell is one deployment of the hot side: a supervisor, the workers that it forks, and the operations
that they serve. An application reaches a cell through two UNIX sockets in one directory, `work.sock` and
`control.sock`.

A cell is the unit of isolation and the unit of capacity. To use more than one cell, call
`HotCell.register` once for each cell. See [Client API](client-api.md#register-a-cell).

## Supervisor

The supervisor is process 1 in the cell. It does the following:

- Accepts connections and queues them.
- Dispatches each connection to a worker.
- Enforces the wall-clock deadline from outside the worker.
- Kills and reaps workers.

The supervisor never evaluates image data, and it doesn't read a request that it dispatches. It passes the
accepted connection itself to a worker over `SCM_RIGHTS` and never calls `recvmsg`, so the caller's
descriptors are still queued on the connection when the worker reads them. When a dispatch fails, the
supervisor peeks at the request to name its operation in the `worker.undispatchable` event.

## Worker

A worker is a child process that the supervisor forks before a request needs it. The supervisor forks one
worker for each slot at boot, and forks a replacement as soon as it reaps a worker that served a request.

A worker is the only process that touches untrusted bytes. It applies the cell's resource limits before it
touches the socket, serves `max_requests_per_worker` requests, and then exits without running finalizers.

## Slot

A slot is the numbered workspace that a worker borrows. A slot holds one directory for each request. That
directory is the request's `$HOME`, and the request's staged files are in it.

The worker creates the directory when the request starts and removes it before the caller receives the
answer. Nothing that a tool writes reaches the next request on that slot.

## Operation

An operation is the unit of work that a cell offers. It's a subclass of `HotCell::Operation` with the
following:

- A routing name.
- Its own `limits`.
- A `perform(inputs, outputs, **payload)` method that declares the payload keys that it accepts as keyword
  arguments.

By default, both sides derive the same routing name from the class path, and the cell side strips the
`Operation` suffix. For example, `ExtractTextOperation` in the cell and `ExtractText` in the application
both answer to `extract_text`. See [Operation API](operation-api.md).

## Inventory

A cell's inventory is the set of operations that it carries. The cell logs its inventory at boot, in
`cell.boot`, and reports it on the control socket, in `describe`.

## Client

A client is the application-side counterpart of an operation. It's a subclass of `HotCell::Client` that
names the cell with `hotcell` and the operation with `operation`, and provides `perform_in_hotcell`.

`perform_in_hotcell` is a blocking call. It sends the request and waits for the cell's answer, up to the
`timeout` that the cell was registered with. See [Client API](client-api.md).

## Tool

A tool is a program that an operation runs in a subprocess with `run_tool`, for example `mutool` or
`ffmpeg`. The tool gets a fully written environment, and `run_tool` bounds how much of its output is
captured. The worker waits for the tool, and the tool sees only the environment that its operation wrote
for it.

Not every operation uses a tool. For example, the Vips operations call libvips directly from the Ruby
worker process.

## Payload and result

The payload is a `Hash` of options. It travels in the request as one JSON object and arrives in `perform`
as keyword arguments.

The result is the `Hash` that an operation returns. It travels in the response the same way.

Neither the payload nor the result carries file contents.

## Inputs and outputs

Inputs and outputs are the open file descriptors that a caller passes. Inputs are read-only and outputs
are write-only. They are the only way that file contents enter or leave a cell.

An operation can read and write the descriptors directly, which is the efficient path. To give a tool a
file on the worker's scratch, ask the descriptor for its `path`:

- An input copies its bytes onto scratch the first time that the operation asks.
- An output's file is sent back through the descriptor when `perform` returns.

See [Inputs and outputs](operation-api.md#inputs-and-outputs).

## Code

Every failure carries a code, and each code is permanent or transient. A permanent failure means that the
input fails this way every time, so the caller can record that verdict against the input. Every uncertain
failure is transient, which means that it might succeed on a retry. See [Response codes](codes.md).
