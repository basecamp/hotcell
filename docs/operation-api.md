---
type: Reference
title: "Operation API"
order: 4
description: "HotCell::Operation's class and instance methods, run_tool, and the Input and Output descriptors that perform receives."
sources:
  - hotcell-server/lib/hot_cell/operation.rb
  - hotcell-server/lib/hot_cell/server/errors.rb
  - hotcell-core/lib/hot_cell/descriptors.rb
  - hotcell-core/lib/hot_cell/naming.rb
  - hotcell-core/lib/hot_cell/declarations.rb
---

# Operation API

This page describes `HotCell::Operation`, the class that you subclass to write work that runs in a cell,
and the `Input` and `Output` objects that `perform` receives. For the application side of the call, see
[Client API](client-api.md).

The code lives in [`hotcell-server/lib/hot_cell/operation.rb`](../hotcell-server/lib/hot_cell/operation.rb)
and [`hotcell-core/lib/hot_cell/descriptors.rb`](../hotcell-core/lib/hot_cell/descriptors.rb).

## Example

The client class in the application and the operation class in the cell share a routing name. The
signature of `perform` (inputs, outputs, payload) is the contract for what crosses the socket. Descriptors
travel as they are, without copies, and the payload travels as one JSON object.

In the application:

```ruby
class TransformImage < HotCell::Client
  hotcell "images"                # the cell that serves this call, by registered name
  operation "images.transform"    # the routing name an operation must answer to
end

# source and destination are Files the app already opened. This is a blocking call that waits for
# a response from the cell.
TransformImage.perform_in_hotcell source, destination,
                                  format: "png",
                                  operations: { resize_to_limit: [ 800, 600 ] }
```

In the cell:

```ruby
require "active_support"
require "active_support/core_ext/numeric"   # for 30.seconds and 1280.megabytes

class TransformImageOperation < HotCell::Operation
  operation "images.transform"    # the same routing name

  # Ceilings for one request enforced by rlimits and the supervisor's clock,
  # clamped to the cell's own limits.
  limits deadline: 30.seconds, memory: 1280.megabytes, file_size: 48.megabytes

  before_fork        { require "my_image_processor" }       # once, in the supervisor
  before_worker_boot { MyImageProcessor.concurrency_set 4 } # in forked worker, before it serves a request

  # The descriptors the caller passed, and the payload as keyword arguments. A missing or undeclared
  # key raises, so the signature is the schema. Declare **payload instead to take the Hash whole.
  def perform(inputs, outputs, format:, operations: {})
    source, = inputs
    destination, = outputs

    # fd_path reads the caller's file in place, with no copy onto scratch, so an input of any size
    # costs nothing against file_size. Reach for source.path only when a tool needs a distinct on-disk
    # copy; that stages the bytes, and the kernel charges the write.
    MyImageProcessor.source(source.fd_path)
                    .apply(format:, operations)
                    .write_to(destination.fd_path)

    # The result: one JSON object, which the caller receives as perform_in_hotcell's return value (in
    # addition to the destination file descriptor)
    { format: format, bytes: File.size(destination.fd_path) }
  end
end
```

A cell serves an operation when one of its operation files requires the operation's file. See
[Cell settings](cell-settings.md#load-order).

## Class methods

### `operation(name = nil)`

Sets the routing name, the name that the operation answers to on the wire. With no argument, returns the
routing name.

If you don't call `operation`, the name derives from the class path: each namespace and the class name in
snake case, joined with dots, with an `Operation` suffix removed. For example,
`Thumbnails::ExtractTextOperation` answers to `thumbnails.extract_text`. An anonymous class must set its
name explicitly.

A subclass doesn't inherit its parent's routing name. It derives its own from its class path unless it
declares one, so it never answers to the same name as its parent.

### `limits(**values)`

Declares this operation's ceilings for one request. The keys are the four request limits: `deadline` in
seconds, and `memory`, `file_size`, and `open_files`. See
[Cell settings](cell-settings.md#request-limits) for what each one enforces. Active Support helpers work:
`1280.megabytes` is an `Integer`, and `30.seconds` becomes a number on arrival. With no arguments, returns
the effective `HotCell::Limits`.

The cell clamps every value to its own limit for the same key, so an operation can narrow a limit and
never widen it. The effective value is the smaller of the two.

`limits` accumulates. Naming one limit changes that limit and keeps the rest of this class's declaration,
or of the nearest ancestor's declaration when this class has none yet. Naming a limit as `nil` withdraws
it, which gives that limit back to the cell's value. See
[Change a shipped operation's limits](#change-a-shipped-operations-limits).

### `before_fork { ... }`

Registers a block that runs once, in the supervisor, at boot. Use it to require and configure libraries.

**Caution:** A `before_fork` block must never evaluate an image. libvips can't survive `fork` after it
evaluates an image: every worker forked after that deadlocks. See
[experiment 1](contributing/experiments.md).

Every megabyte that the supervisor holds is partly copied by every worker, so require only what this
cell's own operations need. See [Cell overhead](contributing/overhead.md).

### `before_worker_boot { ... }`

Registers a block that runs in the worker after the fork and before the worker serves a request. Use it
to size a library, for example `Vips.concurrency_set`. Hot Cell doesn't size libraries for you: size them
against the cell's own `cpus` and `concurrency`.

Configure libraries here rather than in `before_fork`, because library configuration is global. Two
operations that configured the same library in the supervisor would disagree, and the last one registered
would win.

Above `max_requests_per_worker: 1`, one worker can serve operation A, then B, then A. The worker runs these
blocks again whenever the operation changes, so write them as re-entrant setters, not as one-time
initialization.

Hooks from a superclass run before the hooks of its subclasses. This applies to `before_fork` and
`before_worker_boot`.

### `unreadable(*classes)`

Declares the library exception classes that mean "the input can't be decoded", rather than "the operation
broke". When `perform` raises one of them, the cell answers `unreadable`, which is
[permanent](codes.md). `HotCell::UnreadableInput` is always included. A subclass adds to the classes that
its ancestors declared.

### `abstract_operation`

Marks a class that exists to be inherited from, not to be dispatched to.

Every subclass of `HotCell::Operation` registers itself. Without `abstract_operation`, an intermediate
class that holds shared setup would appear in `describe`, accept requests, and answer `failed` from a
`perform` that raises `NotImplementedError`. A subclass of an abstract operation is concrete unless it
also calls `abstract_operation`.

## Instance methods

### `perform(inputs, outputs, **payload)`

Does the work. Hot Cell calls `perform` on a new instance for each request, so nothing in an instance
variable survives into the next request that a reused worker serves.

- `inputs` is an `Array` of `Input` objects, and `outputs` is an `Array` of `Output` objects, in the
  order that the caller passed them.
- The payload arrives as keyword arguments. Declare the keys that you accept, for example
  `format:, operations: {}`, and Ruby validates them on arrival. To take the payload as a `Hash`, declare
  `**payload`. If the operation takes no options, declare neither.
- A missing or undeclared key raises inside `perform`, and the cell answers `failed`.
- The return value is the result: a `Hash` that the caller receives as the return value of
  `perform_in_hotcell`. It travels as JSON.

### `run_tool(*command, env: {}, capture: 64 * 1024, pass: [])`

Runs a tool in a subprocess and returns a `ToolResult` with the following members:

- `status`: the `Process::Status`.
- `out`: the captured standard output.
- `err`: the captured standard error.
- `ok?`: whether `status` is a success.

The arguments are as follows:

| Argument | Description |
| --- | --- |
| `command` | The program and its arguments, for example `"mutool", "draw", ...`. |
| `env` | Environment variables to add or override. |
| `capture` | The maximum number of bytes kept from each of standard output and standard error. `run_tool` reads both streams to the end and discards everything past this limit as it arrives, so a noisy tool can't exhaust the worker's memory. |
| `pass` | Descriptors to hand to the tool at their own descriptor numbers. The tool reaches each one at its `fd_path`, and no byte is copied onto scratch. |

The tool runs with `unsetenv_others: true` and a fully written environment, never a filtered copy of the
worker's environment. This is [invariant 9](design/invariants.md). The environment contains `HOME`,
`TMPDIR`, and `PATH` from the worker, `LANG` and `LC_ALL` set to `C.UTF-8`, and `OMP_NUM_THREADS` and
`OMP_THREAD_LIMIT` from the cell's environment, plus `env`. See
[Bound the OpenMP thread pools](container.md#bound-the-openmp-thread-pools).

A tool's output is influenced by the attacker. Parsing it brings those bytes back into the worker.

## Inputs and outputs

`Input` and `Output` wrap the descriptors that the caller passed. Both sides verify each descriptor when
they wrap it:

- An input must be read-only, and an output must be write-only. An access mode is fixed at open and can't
  be narrowed afterward, so a cell can only decline a descriptor with the wrong mode.
- A descriptor must refer to a regular file. A pipe as an output can deadlock.
- A descriptor must not be open with `O_APPEND`, which would append the conversion to what the file
  already holds.

A failed check raises `HotCell::AccessModeError`.

### `fd_path`

Returns a path that reads or writes the descriptor in place, with no copy onto scratch: `/dev/fd/N` on
Linux. The worker can open it, and so can a tool that received the descriptor through `run_tool`'s
`pass:`.

Prefer `fd_path`. Reading in place costs nothing against `file_size`, so an operation can read a
multi-gigabyte input under a small `file_size`. Each open of `/dev/fd/N` on Linux is a new file
description at offset zero.

On macOS, `fd_path` returns the file's own name, because opening `/dev/fd/N` there shares the worker's
offset. macOS is a development platform only.

### `Input#path`

Copies the input onto the worker's scratch the first time that you call it, and returns the file's name.
Use it only when a tool needs a separate file on disk.

The copy is a write, so `file_size` bounds it. An input larger than the operation's `file_size` fails here
as `killed` with cause `fsize`, which is permanent. The shipped Active Storage operations all read
`fd_path` for this reason.

### `Output#path(extension: nil)`

Names the file on scratch that the operation writes, the first time that you call it. When `perform`
returns, the worker copies that file back through the descriptor and flushes it before it reports success.

With `extension:`, returns a sibling name with that suffix, for a tool that appends its own extension,
such as `pdftoppm`, or that picks its output format from the extension, such as the ImageMagick transform.
Call `adopt(staged)` to rename the sibling onto `path` so that the worker ships it.

An operation can instead write directly through the descriptor at `fd_path`. Then nothing is copied, and
the worker only flushes and measures the file. If the operation fails partway through a direct write, the
caller's file holds partial bytes, where a staged output leaves it empty. In either form, if the outputs
hold zero bytes in total after a successful `perform`, the client reports `unavailable`.

### `staged?`

Returns whether the descriptor has a file on the worker's scratch.

## Change a shipped operation's limits

To give a shipped operation a different budget without editing the gem, redeclare the one limit after the
operation loads, from an operations file:

```ruby
# hotcell/operations/zz_limits.rb
require "active_storage/hot_cell/server/transformers/image/vips"

ActiveStorage::HotCell::Server::Transformers::Image::Vips.limits file_size: 128 * 1024**2
```

The transformer's `deadline`, `memory`, and `open_files` don't change.

Keep the following in mind:

- **Require the operation first.** The class must exist before you can redeclare its limits. `config.rb`
  loads before any operations file, and operations files load in sorted order. Without the `require`, the
  redeclaration must be in an operations file that sorts last, hence the `zz_` prefix. With the
  `require`, the same lines work from any operations file or from `config.rb`. Prefer an operations file
  anyway, so that every declaration about operations is in one place.
- **A subclass copies its parent's limits when it declares.** A subclass that declares
  `limits deadline: 5` takes every other value from its parent, so a narrowing subclass writes only the
  number that it narrows. It takes them once: `limits` resolves to the first ancestor that declared any,
  and after a class stores its own, it stops looking up. Redeclaring the parent afterward doesn't reach a
  child that already declared, so redeclare the child too. A subclass that never declares follows its
  parent.
- **The cell's limits are still the ceiling.** The cell clamps a redeclaration the same way that it clamps
  the original. To get 128MB, the cell's own `file_size` must be at least 128MB. A cell at 64MB gives that
  redeclaration 64MB.

The shipped operations' limits are in [Active Storage operations](active-storage.md#limits).
