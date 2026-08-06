# HotCell

Run untrusted media conversion outside the application, in an unprivileged sibling container with no
network, and pass file descriptors to it rather than paths or bytes.

The threat is untrusted content parsed by libraries that cannot be made safe: libvips, ImageMagick,
LibreOffice, ffmpeg. Today they run inside the application process, where an exploit lands beside the
database credentials, the session secret, and every host the application can reach. HotCell moves them into a
container that holds nothing worth stealing.

```ruby
# in the application
class TransformImage < HotCell::Client
  hotcell "images"
  operation "active_storage.transform_image"
end

TransformImage.perform_in_hotcell [ source ], [ destination ], format: "png",
                                                              operations: { resize_to_limit: [ 800, 600 ] }
```

```ruby
# in the cell
class TransformImage < HotCell::Operation
  operation "active_storage.transform_image"
  limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2
  untrusted_input :in_process

  before_fork        { require "image_processing/vips" }
  before_worker_boot { Vips.block_untrusted true; Vips.concurrency_set 4 }

  def perform(inputs, outputs, payload)
    # inputs and outputs are descriptors the caller opened, staged onto this worker's own scratch
  end
end
```

The two are never both loaded. They are coupled only by an operation name on the wire.

## The gems

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both sides | The wire protocol, descriptor passing, payload validation, the error taxonomy. |
| `hotcell-client` | the application | `HotCell::Client`, cell registration, routing, classification, instrumentation. |
| `hotcell-server` | the cell | The supervisor, the worker, `HotCell::Operation`, the container image. |

Two more, in [`basecamp/activestorage-hotcell`](https://github.com/basecamp/activestorage-hotcell), wire this
into Active Storage's transformer, analyzer, and previewers.

`hotcell-server` depends on `hotcell-core` and nothing else. Not `activesupport`, on purpose: copy-on-write
cost scales with the supervisor's resident heap, so every gem loaded in a cell is paid for on every request,
forever.

## How it works

```
cold side (privileged)                     hot side (unprivileged), one per cell
──────────────────────                     ─────────────────────────────────────
app process                                supervisor                       pid 1
  MyOperation < HotCell::Client              reads in operations, runs before_fork
    wraps IOs as Input/Output                never evaluates image data
    validates the payload                    accepts, queues, dispatches with a slot
    connects to its cell's socket            times the deadline, kills, reaps, cleans up
    sendmsg: JSON + N fds  ─────────────►
                                           worker            serves `reuse` requests
                                             reads the request, resolves the operation
                                             applies limits, posts inputs to its scratch
                                             runs perform
                       ◄─────────────────     one JSON line, then exits or waits
```

The supervisor accepts a connection and hands the connection itself to a worker over `SCM_RIGHTS`, without
ever calling `recvmsg` on it. The caller's descriptors stay queued until someone reads them, and the worker is
the one who does — so the supervisor stays out of the request entirely.

It has to. libvips starts its thread pool on the first evaluation, that pool does not survive `fork`, and a
supervisor that has touched an image forks workers that block forever in `futex_do_wait`. Not the first
worker: every worker.

## Deployment

One Kamal accessory per cell, `network: none`. See [DEPLOYMENT.md](DEPLOYMENT.md), which also covers the two
volume-ownership mistakes that both fail as `EACCES` at boot, and the two exposures `cap-drop ALL` makes
impossible to close.

## Status

Under construction. Nothing here is released.

Working: the wire protocol, the supervisor and its scheduling, worker recycling, resource limits, the
wall-clock deadline, the control channel, the client and its classification, the container image.

Not yet: the `inline` transport for an application's own unit tests, a `cancelled` counter for callers that
give up mid-request, and the canary harness.

## Development

```
bundle install
rake              # every gem's suite: no container, no converter, a few seconds
rake mutations    # break each control in turn and confirm the suite notices
docker/smoke      # the only check that covers network: none and cap-drop
```

The suite needs no container and no converter installed. Fixture operations stand in for the work, so the
protocol, the fork, the descriptor passing, the limits, and the reap are all exercised in milliseconds.

**Cells run uncontainerized in development**, on every platform, so there is one thing to document and one
thing to debug. The reason is macOS and it cannot be engineered around: Docker Desktop runs containers in a
Linux VM, a file descriptor is an index into one kernel's table, and `sendmsg` has nothing meaningful to hand
across two kernels. Native `AF_UNIX` and `SCM_RIGHTS` on macOS are fine; it is the host-to-VM boundary that
cannot carry a descriptor.

What that leaves out is the isolation, which is verified on Linux by `docker/smoke` and in CI.

### Mutation testing

Security controls here fail silently, so a test that would still pass with the control removed is worse than
no test: it reads as assurance. `rake mutations` monkey patches one control away at a time and fails if the
suite does not notice. A control with no mutation test behind it is a comment.

## Design

`HOTCELL-SPEC.md` in the design repository is the authority on the wire contract, the threat model, and the
measurements behind every limit.
