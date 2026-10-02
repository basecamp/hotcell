# Concepts

## The moving parts

A **cell** is one deployment of the hot side: a supervisor, the workers it forks, and the operations
they serve, reachable through two unix sockets in one directory. A cell is the unit of isolation and
the unit of capacity. An application may register several cells by calling `HotCell.register` for
each one.

The **supervisor** is pid 1 in the cell. It accepts connections, queues them, dispatches each to a
worker, enforces the wall-clock deadline from outside, kills and reaps. It never reads a request and
never evaluates a byte of image data -- it hands the accepted connection itself to a worker over
`SCM_RIGHTS` without ever calling `recvmsg`, so the caller's descriptors are still queued on it when
the worker reads them.

A **worker** is a child the supervisor forks before a request needs it: one per slot at boot, and a
replacement as soon as the supervisor reaps one that served. Every untrusted byte is touched there and
nowhere else. It applies the cell's resource limits before touching the socket, serves
`max_requests_per_worker` requests, and exits without running finalizers.

A **slot** is the numbered workspace a worker borrows. It holds one directory per request, which is
that request's `$HOME`, with the request's staged files under `scratch` inside it. The whole thing is
created when the request starts and removed before the caller hears the answer, so nothing a tool
writes reaches the next request on that slot.

An **operation** is the unit of work a cell offers: a subclass of `HotCell::Operation` with a
routing name, its own `limits`, and a `perform(inputs, outputs, **payload)` that declares the
payload keys it wants as keyword arguments. By default, both sides derive the same name from the
class path, and the cell-side `Operation` suffix is stripped. So `ExtractTextOperation` in the cell
and `ExtractText` in the application both answer to `extract_text`. The set of operations a cell
carries is its **inventory** -- logged at boot, advertised on the control socket.

A **client** is the application-side mirror of an operation: a subclass of `HotCell::Client` that
names the cell with `hotcell` and the operation with `operation`, and exposes
`perform_in_hotcell`. That is a blocking call -- it sends the request and waits for the cell's
answer, up to the `timeout` the cell was registered with.

A **tool** is a program an operation runs in a subprocess (e.g., `mutool`, `ffmpeg`) via `run_tool`,
with a fully written environment and bounded capture of its output. The worker waits for it, and the
tool sees only the environment its operation wrote for it. Not every operation uses a tool, for
example the Vips operations call `libvips` directly from the Ruby worker process.

The **payload** is a `Hash` of options, riding the request as its one JSON object and arriving in
`perform` as keyword arguments; the **result** is the `Hash` an operation returns, riding the
response the same way. Neither carries file contents.

**Inputs** and **outputs** are the open file descriptors a caller passes -- inputs read-only,
outputs write-only. They are the only way file contents enter or leave a cell. Asking one for its
`path` materializes a temporary file on the worker's scratch that a tool can take. An input's bytes
are copied there on the first ask, and an output's file is sent back through the descriptor when
`perform` returns.  An operation may read and write directly to the descriptors for efficiency.

A failure carries a **code** -- `unreadable`, `invalid`, `unsupported`, `failed`, `capacity`,
`unavailable`, `timeout`, `protocol`, or `killed` with a cause -- and each code is **permanent** or
**transient**. Permanent means the input will fail this way every time, so the caller may record
that verdict against it. Everything uncertain is transient, meaning it might succeed on a retry.
