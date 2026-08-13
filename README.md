# HotCell

Securely run untrusted code on untrusted inputs. HotCell moves the work out of the application and into
an unprivileged sibling container with no network, and hands it open file descriptors rather than paths
or bytes. Each call is a remote procedure call ("RPC"): the application calls an ordinary Ruby method,
the work runs in the container, and the result comes back as the return value.

HotCell was created to perform safe media conversion. A web application that accepts uploads eventually
hands a stranger's file to libvips, ImageMagick, LibreOffice or ffmpeg to make a thumbnail or a preview.
Those libraries have long histories of exploitable parsing bugs, and running them inside the application
process cannot be made secure. An exploited upload lands beside the database credentials, the session
secret, and every host the application can reach.

HotCell moves that work into a container that holds nothing worth stealing. Media conversion is only the
first use case. An operation is any code, and an input is any file.

## Usage

Two classes cooperate to run code in the cell. The client in the application and the operation in the
cell share a routing name, and the fixed signature — inputs, outputs, payload — is the whole contract
for what crosses the socket. Descriptors travel as descriptors, the payload travels as one JSON object,
and nothing else travels at all.

```ruby
# In the application.
class TransformImage < HotCell::Client
  hotcell "images"                             # the cell that serves this call, by registered name
  operation "active_storage.transform_image"   # the routing name an operation must answer to
end

# source and destination are Files the app opened — inputs read-only, outputs write-only. Their
# descriptors cross the socket. The trailing keywords are Ruby collecting a Hash into the third
# argument: that Hash is the payload, it crosses as one JSON object, and the worker double-splats it
# back into perform's keyword arguments on the other side. This is a blocking call that waits for a
# response from the cell.
TransformImage.perform_in_hotcell source, destination,
                                  format: "png",
                                  operations: { resize_to_limit: [ 800, 600 ] }
```

```ruby
# In the cell's image, loaded from /hotcell/operations at boot.
require "active_support"
require "active_support/core_ext/numeric"   # for 30.seconds and 1280.megabytes

class TransformImageOperation < HotCell::Operation
  operation "active_storage.transform_image"   # the same routing name — the only coupling between the two classes

  # Ceilings for one request — deadline in seconds, memory and file_size in bytes — enforced by
  # rlimits and the supervisor's clock, clamped to the cell's own.
  limits deadline: 30.seconds, memory: 1280.megabytes, file_size: 48.megabytes

  before_fork        { require "image_processing/vips" }   # once, in the supervisor
  before_worker_boot { Vips.concurrency_set 4 }            # in each forked worker, before it serves a request

  # The descriptors the caller passed, and the payload as keyword arguments — a missing or undeclared
  # key raises, so the signature is the schema. Declare **payload instead to take the Hash whole.
  def perform(inputs, outputs, format:, operations: {})
    source, = inputs
    destination, = outputs

    # Asking an input for its path copies the bytes onto this worker's private scratch, so the tool
    # gets a filename the caller never chose. Reading source.io directly skips the copy.
    converted = ImageProcessing::Vips
      .source(source.path)
      .convert(format)
      .apply(operations)
      .call

    # An output's path names a scratch file that is posted back through the descriptor on return.
    IO.copy_stream converted.path, destination.path

    # The result: one JSON object, which the caller receives as perform_in_hotcell's return value.
    { format: format, bytes: File.size(destination.path) }
  end
end
```

## The moving parts

A **cell** is one deployment of the hot side: a supervisor, the workers it forks, and the operations they
serve, reachable through two unix sockets in one directory. A cell is the unit of isolation and the unit of
capacity — an application may register several, and `HotCell.register "images"` names one.

The **supervisor** is pid 1 in the cell. It accepts connections, queues them, dispatches each to a worker,
enforces the wall-clock deadline from outside, kills and reaps. It never reads a request and never evaluates
a byte of image data — it hands the accepted connection itself to a worker over `SCM_RIGHTS` without ever
calling `recvmsg`, so the caller's descriptors are still queued on it when the worker reads them.

A **worker** is a child the supervisor forks. Every untrusted byte is touched there and nowhere else. It
applies the cell's resource limits before touching the socket, serves `max_requests_per_worker` requests,
and exits without running finalizers.

A **slot** is the numbered workspace a worker borrows — two directories. `home` becomes the worker's
`$HOME` and survives between requests, because LibreOffice's profile is expensive and warm is better.
`scratch` holds one request's staged files, and is removed before the caller hears the answer.

An **operation** is the unit of work a cell offers: a subclass of `HotCell::Operation` with a routing name, its
own `limits`, and a `perform(inputs, outputs, **payload)` that declares the payload keys it wants as
keyword arguments. By convention the class takes an `Operation`
suffix — `TransformImageOperation` — while the client keeps the bare name, and the default routing name strips
the suffix, so both sides derive `transform_image`. The set of operations a cell carries is its
**inventory** — logged at boot, advertised on the control socket.

A **client** is the application-side mirror of an operation: a subclass of `HotCell::Client` that names
the cell with `hotcell` and the operation with `operation`, and exposes `perform_in_hotcell`. That is a
blocking call — it sends the request and waits for the cell's answer, up to the `timeout` the cell was
registered with.

A **tool** is a program an operation runs in a subprocess — `soffice`, `mutool`, `ffmpeg` — via `run_tool`,
with a fully written environment and bounded capture of its output. The worker waits for it, and the tool
sees only the environment its operation wrote for it.

The **payload** is a `Hash` of options, riding the request as its one JSON object and arriving in
`perform` as keyword arguments; the **result** is the `Hash` an operation returns, riding the response the
same way. Neither carries file contents.

**Inputs** and **outputs** are the open file descriptors a caller passes — inputs read-only, outputs
write-only. They are the only way file contents enter or leave a cell. Asking one for its `path`
materializes a temporary file on the worker's scratch that a tool can take. An input's bytes are copied
there on the first ask, and an output's file is sent back through the descriptor when `perform` returns.
An operation that reads or writes the descriptor directly never touches the disk.

A failure carries a **code** — `unreadable`, `invalid`, `unsupported`, `failed`, `capacity`, `unavailable`,
`timeout`, `protocol`, or `killed` with a cause — and each code is **permanent** or **transient**. Permanent
means the input will fail this way every time, so the caller may record that verdict against it. Everything
uncertain is transient, meaning it might succeed on a retry.

## How a request works

```mermaid
sequenceDiagram
    participant App as app process<br>(cold side, privileged)
    participant Supervisor as supervisor, pid 1<br>(hot side, unprivileged)
    participant Worker as worker<br>(forked per dispatch)

    App->>Supervisor: one sendmsg — JSON request + N descriptors
    note over Supervisor: never reads the request<br>queues it, or answers capacity
    Supervisor->>Worker: forks, and passes the connection itself over SCM_RIGHTS
    note over Worker: applies the cell's limits before touching the socket<br>reads the request, narrows to the operation's limits
    Worker->>Worker: perform(inputs, outputs, **payload)<br>an input copies to scratch when asked for a path
    Worker->>App: posts the outputs, flushes, answers with one JSON line
    note over Supervisor,Worker: a worker past its deadline is killed as a process group,<br>and the supervisor answers killed
    Worker->>Worker: exits, or waits for the next dispatch
```

1. The application calls `perform_in_hotcell inputs, outputs, payload` on a client class. The client wraps
   each IO as an `Input` or `Output`, verifies its access mode — inputs read-only, outputs write-only —
   validates the payload, and connects to the cell's `work.sock`.
2. One `sendmsg` carries one JSON line and every descriptor.
3. The supervisor accepts and dispatches, or answers `capacity` when the queue is full.
4. The worker narrows to the operation's limits, clamped to the cell's, before reading any untrusted byte,
   and re-runs `before_worker_boot` when the operation differs from the last one it served.
5. `perform` runs on a fresh operation instance. An `Input` copies itself onto the slot's scratch the first
   time the operation asks for its `path`; an operation that reads the descriptor directly never pays for
   the copy. Outputs are posted back through their descriptors and flushed before success is reported.
6. One JSON line answers: `ok` with the result and the timing, or a failure with its code.
7. The supervisor enforces the deadline from outside, because a thread inside a C extension cannot be
   interrupted from within. A worker past its deadline is killed as a process group, and the supervisor —
   the only survivor holding the connection — answers `killed` with the cause.
8. The client raises the exception class registered for that side of the permanent split, and publishes a
   `perform.hot_cell` notification either way.

## How to get started

Everything about a cell lives in a `hotcell/` directory in the application root, apart from the client
configuration in the application itself. That directory holds:

- a `Gemfile` for what the operations need,
- a `Dockerfile` that builds the cell's image,
- a `config.rb` for the cell's own settings, and
- an `operations/` directory of Ruby files the cell loads at boot.

Running `bin/rails hotcell:install` creates all of them.

### Write an operation

Declare the routing name and the limits, hook library loading, and perform:

```ruby
# hotcell/operations/extract_text_operation.rb
require "active_support"
require "active_support/core_ext/numeric"

class ExtractTextOperation < HotCell::Operation
  operation "documents.extract_text"
  limits deadline: 30.seconds, memory: 512.megabytes, file_size: 16.megabytes

  before_fork { require "pdf/reader" }
  unreadable PDF::Reader::MalformedPDFError

  # This operation takes no options, so it declares no keywords at all — an empty payload
  # double-splats into nothing.
  def perform(inputs, outputs)
    source, = inputs
    destination, = outputs

    reader = PDF::Reader.new(source.path)
    File.write destination.path, reader.pages.map(&:text).join("\n")

    { pages: reader.page_count }
  end
end
```

`before_fork` runs once in the supervisor and must never evaluate an image; `before_worker_boot` runs in the
worker and is where a library gets sized. `unreadable` names the library exceptions that mean "this input
cannot be decoded" — the one verdict an operation can make permanent. An operation that shells out calls
`run_tool "mutool", "draw", ...` and gets the exit status and bounded output back; the tool sees only the
environment the operation wrote.

### Configure and build the cell

`bin/rails hotcell:install` writes the `hotcell/` directory — the `Dockerfile`, the `Gemfile`,
`config.rb`, and an empty `operations/` directory. There is no published base image to inherit from. The installed Dockerfile is
the complete recipe, and it is yours to customize. A file you have already edited is never overwritten.

Two customization points matter most. In the Dockerfile, install the tools your operations run — and
nothing else, because which tools a cell holds is what decides its blast radius:

```dockerfile
# hotcell/Dockerfile (excerpt)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libvips42 mupdf-tools ffmpeg && \
    rm -rf /var/lib/apt/lists/*
```

And `config.rb` loads at boot before any operation, so the cell's own settings live there:

```ruby
# hotcell/config.rb
require "active_support"
require "active_support/core_ext/numeric"

HotCell.limits concurrency: 4, queue_size: 8, deadline: 60.seconds, memory: 1536.megabytes
```

The image's entrypoint is `hotcell`, which loads `config.rb`, then the operations in sorted order, and
boots the supervisor on `HOTCELL_DIR`.

### Run it in development

A cell can run in development either as a container or as a plain, uncontainerized process. The
container route works only on Linux — on macOS the containers run in a VM, and descriptor passing
will not work. The resource limits and the deadline apply either way.

We recommend the uncontainerized process in development, managed by foreman beside the Rails server,
so there is one setup to document and one to debug. Give the cell its own directory in the app
repository, with its own `Gemfile` — the same one the image build copies — and add one line per cell
to `Procfile.dev`:

```procfile
web: HOTCELL_ROOT=tmp/hotcell bin/rails server
cell: BUNDLE_GEMFILE=hotcell/Gemfile HOTCELL_CONFIG=hotcell/config.rb HOTCELL_OPERATIONS=hotcell/operations HOTCELL_DIR=tmp/hotcell/documents bundle exec hotcell
```

`bin/dev` boots both. The app finds the sockets under `tmp/hotcell`, and the cell keeps its own bundle
so the two sides stay separate in development the way they are in production.

### Deploy it with Kamal

One accessory per cell. An accessory rather than an app role, because only an accessory can set
`network: none` — and it targets the app's own hosts, because a descriptor cannot cross machines.

```yaml
accessories:
  documents:
    image: registry.example.com/myapp-hotcell-documents:latest
    roles: [ web, jobs ]                       # a cell always lives on its caller's host
    volumes:
      - hotcell-documents:/run/hotcell/cell    # the socket directory, shared with the app
    options:
      network: none
      read-only: true
      tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
      memory: 2g
      cap-drop: ALL
```

This is the short version. [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) has the full flag set, why each flag
matters, and the two volume-ownership mistakes that both fail as `EACCES` at boot.

### Point a client at it

Register the cell once, with the application's own exception classes for the two
sides of the permanent split, then declare a client per operation:

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]   # unset means every cell is off

HotCell.register "documents",
  permanent: MyApp::UnreadableDocument,
  transient: MyApp::ConversionTemporarilyUnavailable

class ExtractText < HotCell::Client
  hotcell "documents"
  operation "documents.extract_text"
end

result = ExtractText.perform_in_hotcell source, destination
result[:pages]
```

`HotCell.root` names the directory that holds one subdirectory of sockets per cell, so this cell's live
at `$HOTCELL_ROOT/documents`. In production that is the shared volume. The accessory above mounts
`hotcell-documents` at `/run/hotcell/cell`, the app mounts the same volume at `/run/hotcell/documents`,
and `HOTCELL_ROOT` is `/run/hotcell`. In development a cell runs uncontainerized, so use the app's own
scratch space — set `HOTCELL_ROOT=tmp/hotcell` and boot the cell with
`HOTCELL_DIR=tmp/hotcell/documents`. Leaving `HOTCELL_ROOT` unset turns every cell off — `enabled?`
answers false, and `perform_in_hotcell` raises `HotCell::CellNotConfigured`. There is no automatic
in-process fallback. A caller that wants one checks `enabled?` and takes its old path, which is how an
application rolls this out as a configuration change rather than a release.

### Watch it

Every `perform_in_hotcell` call — success or failure — emits an Active Support notification named
`perform.hot_cell`, and the cell answers `metrics` on its control socket even while the work socket is
saturated. The [Observability](#observability) section covers both, with the metrics worth collecting and
the failure modes worth alerting on.

## Observability

The recommended approach, in four parts:

- **Metrics collection.** Poll `cell.metrics` on a schedule — for example with a
  [Yabeda](https://github.com/yabeda-rb/yabeda) `collect` block. The control socket answers even
  while the work socket is saturated, and it is host-local, so the poller must be a process on the
  cell's own host. Watch `queued`, `queue_high_water`, `cancelled`, and `killed_by` cause.
- **Per-call telemetry.** Subscribe to the `perform.hot_cell` notification for logging, metrics, or both.
  It fires on every call, success or failure, and it is the only signal that survives a dead cell — an
  unreachable socket comes back as code `unavailable`, so the primary alarm belongs here.
- **The healthcheck.** The installed Dockerfile wires `hotcell-health` up as the Docker `HEALTHCHECK`. It
  probes the supervisor's control socket from inside the container, where `network: none` does not apply.
  Healthy means the supervisor answers, not that a worker is free.
- **Logs.** The cell writes one JSON object per event to stdout, so Kamal's container log capture ships
  it wherever your logs go. Alert on the presence of `worker.crashed`, and on `worker.killed` by cause —
  `memory` means bombs, `deadline` means wedged tools.

## The gems

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both sides | The wire protocol, descriptor passing, payload validation, the error taxonomy. |
| `hotcell-client` | the application | `HotCell::Client`, cell registration, routing, classification, instrumentation. |
| `hotcell-server` | the cell | The supervisor, the worker, `HotCell::Operation`, the container image. |
| `activestorage-hotcell-client` | the application | The transformer, analyzer, and previewers Rails is configured with. |
| `activestorage-hotcell-server` | the cell | The `transformers.image.*`, `analyzers.image.*`, `analyzers.media.ffprobe`, and `previewers.*` operations. |

They are in one repository because they are one system today: writing the Active Storage gems has already twice
required changing `hotcell-server` first. Splitting them is cheap while nothing is published.

`hotcell-server` depends on `hotcell-core` and nothing else — not `activesupport` — because there is no reason
for it to, and a smaller graph inside the blast radius is a smaller thing to audit. That is a budget, not a rule
about what a cell may run: an operation is free to require whatever it needs, because the container is the
control rather than the contents.

## Active Storage

The two `activestorage-hotcell-*` gems are the shipped, worked example of building on HotCell — the five
media operations, and the transformer, analyzer and previewers Rails is configured with. They are
documented in [README-active-storage.md](README-active-storage.md).

## Status

Under construction. Nothing here is released.

Working: the wire protocol, the supervisor and its scheduling, worker recycling, resource limits, the
wall-clock deadline, the control channel, the client and its classification, the container image, and the
Active Storage integration converting real images, PDFs and video.

## Development

```
bundle install
rake              # every suite
rake hotcell      # only the suites that need no tool installed
rake rubocop      # style, one configuration for all five gems
docker/smoke      # the only check that covers network: none and cap-drop
```

**The three hotcell gems need no container and no tool**, and `rake hotcell` is what keeps that honest —
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
setting a variable, running a tool, and finding that the tool never saw it. Where a control has no
reachable trigger and so cannot be tested, it says so where it lives.

## Design

[docs/HOTCELL-SPEC.md](docs/HOTCELL-SPEC.md) is the authority on the wire contract, the threat model, and the
measurements behind every limit. Where the code departs from it, the code says so and why — `unsupported` being
transient is the one worth knowing about.
