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
  before_worker_boot { Vips.concurrency_set 4 }

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
| `activestorage-hotcell-client` | the application | The transformer, analyzer, and previewers Rails is configured with. |
| `activestorage-hotcell-server` | the cell | `transform_image`, `analyze_image`, `preview_pdf`, `preview_video`, `probe_media`. |

They are in one repository because they are one system today: writing the Active Storage gems has already twice
required changing `hotcell-server` first. Splitting them is cheap while nothing is published.

`hotcell-server` depends on `hotcell-core` and nothing else — not `activesupport` — because there is no reason
for it to, and a smaller graph inside the blast radius is a smaller thing to audit. That is a budget, not a rule
about what a cell may run: an operation is free to require whatever it needs, because the container is the
control rather than the contents.

**`activestorage-hotcell-server` does not load Active Storage either**, despite the name. The name says which
consumer it serves, not what it links against.

## Active Storage

```ruby
config.active_storage.variant_processor = ActiveStorage::HotCell::Transformer
config.active_storage.analyzers.prepend ActiveStorage::HotCell::ImageAnalyzer
config.active_storage.previewers = [ ActiveStorage::HotCell::PdfPreviewer, ActiveStorage::HotCell::VideoPreviewer ]
```

Three things break the moment `variant_processor` is a class rather than a symbol, and the client gem exists to
close them.

**The analyzers go silent.** The built-in image analyzers gate `accept?` on `variant_processor` being `:vips` or
`:mini_magick`, so a class value makes them all decline, `analyzer_class` falls through to `NullAnalyzer`, and
the blob is marked analyzed with no dimensions at all.

**The previewers answer `accept?` by shelling out.** `MuPDFPreviewer.accept?` runs `mutool` and
`VideoPreviewer.accept?` runs `ffmpeg`, with `system`, from inside a web request. Once those binaries leave the
application image both answer false, `previewable?` goes false with them, and previews stop existing with no
exception and no alert.

**The jobs retry nothing useful.** `TransformJob`, `AnalyzeJob`, `PreviewImageJob` and `CreateVariantsJob` each
declare `retry_on ActiveStorage::IntegrityError` and nothing else, and ActiveJob has no default retry — so
`capacity`, the one verdict whose whole point is "try later", fails its job outright on the first attempt.
`ActiveStorage::HotCell.retry_transient_failures!` teaches them the transient class.

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

One Kamal accessory per cell, `network: none`. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), which
also covers the two volume-ownership mistakes that both fail as `EACCES` at boot, and the two
exposures `cap-drop ALL` makes impossible to close.

## Status

Under construction. Nothing here is released.

Working: the wire protocol, the supervisor and its scheduling, worker recycling, resource limits, the
wall-clock deadline, the control channel, the client and its classification, the container image, all five
Active Storage operations converting real images, PDFs and video, and the transformer, analyzer and previewers
Rails is configured with.

`activestorage-hotcell-client` depends on [rails/rails#58384](https://github.com/rails/rails/pull/58384), which
is unmerged — the Gemfile pins the branch. Without it a class value leaves `ActiveStorage.variant_transformer`
at `nil` and the first variant dies with `NoMethodError` rather than a boot error, which is what
`ActiveStorage::HotCell.verify_installation!` exists to catch.

Not yet: the `inline` transport for an application's own unit tests, a `cancelled` counter for callers that give
up mid-request, and the canary harness.

## Development

```
bundle install
rake              # every suite
rake hotcell      # only the suites that need no converter installed
rake mutations    # break each control in turn and confirm the suites notice
docker/smoke      # the only check that covers network: none and cap-drop
```

**The three hotcell gems need no container and no converter**, and `rake hotcell` is what keeps that honest —
CI runs it on a machine with nothing installed. Fixture operations stand in for the work, so the protocol, the
fork, the descriptor passing, the limits and the reap are all exercised in milliseconds.

The two Active Storage gems convert real files rather than pretending to, so they need libvips, mutool, ffmpeg
and ffprobe.

**Nothing loads libvips into a test process.** libvips creates its thread pool the first time it processes an
image, and that pool does not survive `fork`: a child forked afterwards waits forever for a worker thread that
does not exist. Those suites boot real cells by forking, so the operations load inside the cell, the fixtures
are generated by CLI tools, and `Cell.boot` refuses to fork a process that has libvips loaded.
`fork_safety_test.rb` holds both halves of that, because a test that only showed the good case would not
establish that the hazard is real.

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

[docs/HOTCELL-SPEC.md](docs/HOTCELL-SPEC.md) is the authority on the wire contract, the threat model, and the
measurements behind every limit. Where the code departs from it, the code says so and why — `unsupported` being
transient is the one worth knowing about.
