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

  before_fork        { require "image_processing/vips" }
  before_worker_boot { Vips.concurrency_set 4 }

  def perform(inputs, outputs, payload)
    # inputs and outputs are descriptors the caller opened; asking one for its path stages it onto
    # this worker's own scratch, and reading the descriptor directly never pays for the copy
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

Everything the application side defines lives under `ActiveStorage::HotCell::Client` and everything the cell
side defines lives under `ActiveStorage::HotCell::Server`. That is not a tidying convention. The two gems are
never both loaded in production — and a cell is forked from a process that may well have loaded the client,
after which a shared name is a superclass mismatch while the cell boots. Two namespaces make that impossible
rather than avoided.

## Active Storage

```ruby
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Vips
config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::PdfPreviewer,
                                     ActiveStorage::HotCell::Client::VideoPreviewer ]
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
declare `retry_on ActiveStorage::IntegrityError` and nothing else, and ActiveJob does not retry by default. The
railtie adds the transient class to all four, on the same policy they already use.

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
                                           worker            serves `max_requests_per_worker` requests
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

`activestorage-hotcell-client` depends on
[rails/rails#58384](https://github.com/rails/rails/pull/58384), which is merged and unreleased — so the
Gemfile tracks `main` until 8.2 ships and the gemspec floor can name a version. It adds the `Class` arm the
engine assigns `ActiveStorage.variant_transformer` from, and an `else` that raises at boot rather than
leaving it `nil` for the first variant to die on.

Not yet, in the order they matter:

**A library-option allowlist.** `loader` and `saver` reach ImageProcessing exactly as Rails passes them, so a
caller can set `loader: { unlimited: true }` and remove libvips' own denial-of-service limits. That is the
capability Rails gives a caller today, and it is tolerable here only because the cell's limits are outside the
library — `RLIMIT_DATA`, `RLIMIT_FSIZE` and the wall-clock deadline still apply, so the caller buys a killed
worker. The fix is an explicit allowlist of the keys permitted inside each: `page`, `n`, `quality`, `strip`
yes; `unlimited`, `access`, `fail-on`, `revalidate` no. Deriving that list is the work, and it must be one
visible list rather than a filter hidden in a translation step.

**An ImageMagick-compatible transformer and analyzer.** `Transformers::Vips` and
`Analyzers::ImageAnalyzer::Vips` are named for their toolchain so these can sit beside them. Until they exist,
URLs minted on `mini_magick` — carrying `coalesce`, or top-level `quality` and `strip` — are refused, exactly
as they raise under Rails on vips. An application moving between the two rewrites them at its own boundary in
the meantime, the way BC4 does.

Also outstanding: the canary harness.

## Development

```
bundle install
rake              # every suite
rake hotcell      # only the suites that need no converter installed
rake rubocop      # style, one configuration for all five gems
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

### Testing a control

Security controls here fail silently, so a test that would still pass with the control removed is worse than
no test: it reads as assurance. Every control is covered by a test that observes the behaviour the control
produces, rather than by an assertion that the control is written down — `unsetenv_others: true` is proved by
setting a variable, running a converter, and finding that the converter never saw it. Where a control has no
reachable trigger and so cannot be tested, it says so where it lives.

## Design

[docs/HOTCELL-SPEC.md](docs/HOTCELL-SPEC.md) is the authority on the wire contract, the threat model, and the
measurements behind every limit. Where the code departs from it, the code says so and why — `unsupported` being
transient is the one worth knowing about.
