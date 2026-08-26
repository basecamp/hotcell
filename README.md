![hotcell-logo](docs/hotcell-logo.png)

# HotCell

Securely run untrusted code on untrusted inputs. HotCell lets you move that work out of your application
and into an unprivileged sibling container: no network, no credentials, and nothing on its filesystem
worth stealing.

Inputs and outputs travel as file descriptors over a UNIX socket on a shared volume. Each call is a
remote procedure call ("RPC"): your application calls an ordinary Ruby method, the arguments are
forwarded to the container where the work runs in a forked worker process with strict limits
applied, and the results are returned or written to the output file.

<!-- regenerate with `rake toc` -->

<!-- toc -->

- [Status](#status)
- ["Why would I use this?"](#why-would-i-use-this)
- [Extensibility](#extensibility)
- [The gems](#the-gems)
- [The moving parts](#the-moving-parts)
- [How a request works](#how-a-request-works)
- [Usage](#usage)
  * [Using the Active Storage operations](#using-the-active-storage-operations)
  * [Using custom operations](#using-custom-operations)
- [Observability](#observability)
  * [Logs](#logs)
  * [Metrics collection](#metrics-collection)
  * [Per-call telemetry](#per-call-telemetry)
  * [Container healthcheck](#container-healthcheck)
  * [Rails healthcheck](#rails-healthcheck)
- [Development](#development)
- [Design](#design)

<!-- tocstop -->

## Status

This is still pre-release software! It may break in interesting ways. Use with caution until there's a v1.0 release.

The `activestorage-hotcell-client` gem needs Rails 8.2, which is unreleased: variant processing can only
be swapped out from [rails/rails#58384](https://github.com/rails/rails/pull/58384)
([`5ea765e5`](https://github.com/rails/rails/commit/5ea765e5b00085a22f5cbe863c0d2ac765428242)) onward. Track
`rails/rails` `main` until it ships — see [Using the Active Storage operations](#using-the-active-storage-operations).

## "Why would I use this?"

Your Rails application accepts uploads, so somewhere in it there's a line like this:

```ruby
blob.variant(resize_to_limit: [ 800, 600 ]).processed
```

If you think about what that line actually does, it's scary. An attacker just handed you a crafted
file, and Rails is about to hand it to libvips -- a few hundred thousand lines of C whose entire job
is to guess at file formats it has never seen before and delegate handling to ANOTHER
format-specific library that you may not even be aware of.

libvips, ImageMagick, ffmpeg and LibreOffice all have long histories of memory-safety bugs, and
every one of them is running by default in the same container that holds your database credentials,
your session secret, and a route to every network service the app uses. The potential blast radius
is large.

HotCell gives that work its own container and its own forked process, holding nothing an attacker
wants. Take libvips and ffmpeg out of your application image entirely and keep them isolated in the
Cell. Code execution in that process buys an attacker a read-only input descriptor, a write-only
output descriptor, and the scratch of whatever else the cell is converting. The blast radius is much
smaller than if that attack succeeded in your application code.

If you're a Rails developer, this project also ships drop-in replacements for the Active Storage
analyzers, transformers, and previewers so that using HotCell only requires configuration changes,
not code changes.

In our environment, using HotCell adds about 8 milliseconds per call, and one more container to
deploy on each host. We think this is a very good trade for the improved security posture.

## Extensibility

HotCell was designed to be flexible and configurable beyond just the media conversion use case:

- multiple cells can be configured per host
- multiple input and output files are supported
- custom operations have a simple Active-Job-like `#perform` API
- cell limits are configurable: memory, wall clock time, disk usage, and more
- bring your own container by using the included conformance test
- customize how often workers are re-forked, for performance optimization

So you could try using HotCell for handling ZIP files, or for compute workloads that might be CPU
hogs. Whatever is putting your trusted core application at risk, move it out!

## The gems

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both sides | The wire protocol, descriptor passing, payload validation, the error taxonomy. |
| `hotcell-client` | the application | `HotCell::Client`, cell registration, routing, classification, instrumentation. |
| `hotcell-server` | the cell | The supervisor, the worker, `HotCell::Operation`, the container image. |
| `activestorage-hotcell-client` | the application | The transformer, analyzer, and previewers Rails is configured with. |
| `activestorage-hotcell-server` | the cell | The `transformers.image.*`, `analyzers.image.*`, `analyzers.media.ffprobe`, and `previewers.*` operations. |

They are in one repository because they are being developed together today. We may split out the
Active Storage gems into another repository at a later date.

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

A **worker** is a child the supervisor forks. Every untrusted byte is touched there and nowhere
else. It applies the cell's resource limits before touching the socket, serves
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

## How a request works

```mermaid
sequenceDiagram
    participant App as app process<br>(cold side, privileged)
    participant Supervisor as supervisor, pid 1<br>(hot side, unprivileged)
    participant Worker as worker<br>(forked per dispatch)

    App->>Supervisor: one sendmsg -- JSON request + N descriptors
    note over Supervisor: never reads the request<br>queues it, or answers capacity
    Supervisor->>Worker: forks, and passes the connection itself over SCM_RIGHTS
    note over Worker: applies the cell's limits before touching the socket<br>reads the request, narrows to the operation's limits
    Worker->>Worker: perform(inputs, outputs, **payload)<br>an input copies to scratch when asked for a path
    Worker->>App: posts the outputs, flushes, answers with one JSON line
    note over Supervisor,Worker: a worker past its deadline is killed as a process group,<br>and the supervisor answers killed
    Worker->>Worker: exits, or waits for the next dispatch
```

1. The application calls `perform_in_hotcell inputs, outputs, payload` on a client class. The client wraps
   each IO as an `Input` or `Output`, verifies its access mode -- inputs read-only, outputs write-only --
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
   interrupted from within. A worker past its deadline is killed as a process group, and the supervisor --
   the only survivor holding the connection -- answers `killed` with the cause.
8. The client raises the exception class registered for that side of the permanent split, and publishes a
   `perform.hot_cell` notification either way.

## Usage

The first section covers using HotCell's Active Storage operations straight out of the box. The
second section covers writing and using your own custom operations in HotCell.

### Using the Active Storage operations

The two `activestorage-hotcell-*` gems run Active Storage's variants, analysis, and previews in a
cell instead of in the application. You application code doesn't need to change, though you will
need to deploy a Kamal accessory (or whatever flavor of sidecar container your infrastructure
supports).

#### How to get started

**Install.** Add the client gem to the application:

```ruby
# Gemfile -- the application
gem "activestorage-hotcell-client"
```

The Active Storage gems are what need the unreleased Rails 8.2 (see [Status](#status)); the
`hotcell-*` gems themselves do not require Rails.

Then run `bin/rails hotcell:install` which creates:

- `hotcell/Gemfile` for what the operations need,
- `hotcell/Dockerfile` that builds the cell's image,
- `hotcell/config.rb` for the cell's own settings, and
- `hotcell/operations/` directory of Ruby files the cell loads at boot.

Everything about the cell lives in this `hotcell/` directory in the application root, separate from the
client configuration and the application code.

Add the server gem to the cell's `Gemfile`, and load the operations that match the classes the
application will name -- requiring an operation's file is what serves it:

```ruby
# hotcell/Gemfile -- the cell
gem "activestorage-hotcell-server"
```

```ruby
# hotcell/operations/active_storage.rb
require "active_storage/hot_cell/server/transformers/image/vips"
require "active_storage/hot_cell/server/analyzers/image/vips"
require "active_storage/hot_cell/server/analyzers/media/ffprobe"
require "active_storage/hot_cell/server/previewers/pdf/mutool"
require "active_storage/hot_cell/server/previewers/video/ffmpeg"
```

💡 This section's examples use libvips, mutool, and ffmpeg; `Transformers::Image::Magick` and
`Analyzers::Image::Magick` use ImageMagick instead, and `Previewers::Pdf::Poppler` uses Poppler. If
your application is currently using `variant_processor = :magick` then to retain compatibility you
should replace references to "vips" or `Vips` with "magick" or `Magick` in this section.

**Configure the application.** Register the cell in an initializer, with an application exception
class for each side of the permanent split:

```ruby
# config/initializers/hotcell.rb
# These environment variables are set in your deployment configuration
HotCell.root  = ENV["HOTCELL_ROOT"]  # unset means every cell is off
HotCell.group = ENV["HOTCELL_GROUP"] # the gid shared between app and cell

# Quick health check at boot. Warns about a cell that is unreachable, slower than this client waits, or in the wrong group.
Rails.application.config.after_initialize { HotCell.describe_cells }
```

`HotCell.root` names the directory that holds one subdirectory of sockets per cell, so this cell's
sockets live at `$HOTCELL_ROOT/active_storage`. Note that omitting `HOTCELL_ROOT` off makes every
variant, analysis, and preview raise `HotCell::CellNotConfigured` rather than fall back in process.

Then tell Rails which classes to use:

```ruby
# config/application.rb
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Image::Vips
config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Image::Vips,
                                    ActiveStorage::HotCell::Client::Analyzers::Video::FFprobe,
                                    ActiveStorage::HotCell::Client::Analyzers::Audio::FFprobe ]
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::HotCell::Client::Previewers::Video::FFmpeg ]
```

For every class you name here, the cell must load the matching operation and the cell's image must
have installed the underlying library or tool.

Rails' own classes mix freely with these in the `analyzers` and `previewers` arrays, so you can
choose to offload only specific operations to HotCell:

```ruby
# PDF previews handled by HotCell, video previews still in the application
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::Previewer::VideoPreviewer ]
```

**Run it in development.** A cell can run in development either as a container or as a plain,
uncontainerized process. The container route works only on Linux (on macOS the containers run in a
VM, and descriptor passing will not work), so we recommend the plain process, managed by foreman
beside the Rails server. The resource limits and the deadline apply either way. The cell keeps its
own bundle -- the same `hotcell/Gemfile` the image build copies -- so the two sides stay separate in
development the way they are in production.

Add an entry for your cell to `Procfile.dev`:

```procfile
web: HOTCELL_ROOT=$PWD/tmp/hotcell-sockets bin/rails server
cell: BUNDLE_GEMFILE=$PWD/hotcell/Gemfile HOTCELL_CONFIG=$PWD/hotcell/config.rb HOTCELL_OPERATIONS=$PWD/hotcell/operations HOTCELL_DIR=$PWD/tmp/hotcell-sockets/active_storage bundle exec hotcell
```

Then `bin/dev` boots both, and the app finds the sockets under `tmp/hotcell-sockets`.

#### Configure the cell and operation limits

`hotcell/config.rb` loads when the cell boots, before any operation. Declare the cell's limits
there:

```ruby
# hotcell/config.rb
HotCell.limits concurrency: 4, queue_size: 8, deadline: 60, memory: 1536 * 1024**2
```

Each operation declares its own `limits`, clamped to the cell's. To change an operation's default
limits, set them from an operations file:

```ruby
# hotcell/operations/zz_limits.rb
require "active_storage/hot_cell/server/transformers/image/vips"
ActiveStorage::HotCell::Server::Transformers::Image::Vips.limits file_size: 256 * 1024**2
```

[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) explains every setting and how to size the numbers against
the container's own flags, and [docs/TUNING.md](docs/TUNING.md) covers measuring your own workload.

#### Configure and deploy the HotCell container

There is no published base image. The installed `Dockerfile` is only a base recipe, and you should
customize it for your application.

Install the system packages your operations require:

```dockerfile
# hotcell/Dockerfile (excerpt)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libvips42 mupdf-tools ffmpeg && \
    rm -rf /var/lib/apt/lists/*
```

Build the image from the `hotcell/` directory and deploy it as a second container beside the
application, on the same host, sharing one volume that holds the sockets. With Kamal, that is one
accessory per cell:

```yaml
# config/deploy.yml -- the cell
accessories:
  active_storage:                               # the cell's name; the app registers it under this
    image: your.registry.com/your-image:latest
    roles: [ web, jobs ]                        # a cell always lives on its caller's host
    network: none                               # an accessory key, never an option
    volumes:
      - hotcell-sockets:/run/hotcell/cell       # directory containing the IPC sockets
    options:
      # Performance. Docker applies no limit if unspecified.
      cpus: 2
      memory: 2g
      memory-swap: 2g                           # equal to memory, or swap defeats the limit

      # Security. Be cautious changing these, as that may impact security posture.
      read-only: true
      cap-drop: ALL
      security-opt: no-new-privileges:true
      user: 10001:10001
      pids-limit: 512

      # Both: size=512m is performance, the three flags before it are security.
      tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
    env:
      clear:
        HOTCELL_DIR: /run/hotcell/cell          # where this cell writes its two sockets
```

And the application's half, mounting the same volume:

```yaml
# config/deploy.yml -- the app
servers:
  web:
    hosts: [ ... ]
    options:
      group-add: 10001                          # the cell's gid, and what admits the app to its sockets
  jobs:
    hosts: [ ... ]
    options:
      group-add: 10001

volumes:
  - hotcell-sockets:/run/hotcell/active_storage # $HOTCELL_ROOT/<registered cell name>

env:
  clear:
    HOTCELL_ROOT: /run/hotcell
    HOTCELL_GROUP: 10001                        # must match group-add above
```

The two mount paths differ, and only the volume name has to match: a cell always writes its sockets
to `HOTCELL_DIR`, and the app resolves a cell's name under `HOTCELL_ROOT`. Give each cell its own
volume -- two accessories sharing one would write `work.sock` over each other.

Without Kamal, the same two containers need `--volume hotcell-sockets:/run/hotcell/cell` and the
security flags above on the cell, and `--volume hotcell-sockets:/run/hotcell/active_storage`,
`--group-add 10001` and `HOTCELL_ROOT=/run/hotcell` on the app.

Once a file type's processing has moved into the cell, remove its packages (for example `libvips`)
from the application image -- that removal is the security win. Remove them only after the cell
handles the type: Rails' own previewers and analyzers look for their tool in `accept?`, so a package
removed too early turns that processing off without an error.

[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) covers all of this in detail: every container flag, how to
size the numbers, the shared group, bringing your own container, and where scratch lives.

### Using custom operations

Everything above still applies: the same `hotcell/` directory, the same limits, the same container,
the same deployment. What changes is that you write both sides of the call yourself.

#### Write an operation

The client class in the application and the matching operation class in the cell share a routing
name. The fixed signature of the `#perform` method -- inputs, outputs, payload -- is the contract
for what crosses the socket. Descriptors travel as-is (without additional copies) and the payload
travels as one JSON object.

In the application, the client class and call site might look like:

``` ruby
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


The operation will run in the cell. Declare the routing name and the limits, hook library loading,
and `#perform`:

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
    { format: format, bytes: File.size(destination.path) }
  end
end
```

`before_fork` runs once in the supervisor and must never evaluate an image; `before_worker_boot`
runs in the worker and is where a library gets sized. `unreadable` names the library exceptions that
mean "this input cannot be decoded", a permanent verdict. An operation that shells out calls
`run_tool "mutool", "draw", ...` and gets the exit status and bounded output back; the tool sees
only the environment the operation wrote.

A subclass inherits the `hotcell` name but not the `operation` name. The operation name is the wire
name, so to avoid answering to the same name as its parent, it derives its own from its class path
unless one is declared.

#### Configure the application

The initializer does not change shape: register the cell your client classes name, with exception
classes that fit the domain. Nothing under `config.active_storage` applies. This example
additionally declares custom base classes for exceptions, which can be useful when wrapping existing
libraries.

```ruby
HotCell.register "images",
  permanent: MyApp::UnreadableImage,
  transient: MyApp::ConversionTemporarilyUnavailable
```

Leaving `HOTCELL_ROOT` unset turns every cell off -- `enabled?` answers false, and
`perform_in_hotcell` raises `HotCell::CellNotConfigured`. There is no automatic in-process fallback:
a caller that wants one checks `enabled?` and takes its old path, which is how an application rolls
a cell out as a configuration change rather than a release.

#### Configure the cell

The cell's `Gemfile` names `hotcell-server` directly -- the Active Storage server gem is only needed
for the shipped operations -- plus whatever gems the operation itself uses:

```ruby
# hotcell/Gemfile -- the cell
gem "hotcell-server"
gem "my_image_processor"
```

The operation file goes in `hotcell/operations/`, which the cell requires in sorted order at boot,
after `config.rb`. The `Dockerfile` installs whatever tools the operation shells out to. `config.rb`
itself does not change: the cell's limits are declared there, and the operation's own `limits` ride
its class, clamped to the cell's exactly as the shipped ones are.

## Observability

Some strategies that are working for us to monitor HotCell, which we recommend you add to your
application. (Some of these things may show up more-fully-formed in a future release.)

### Logs

The cell writes one JSON object per event to stdout, so whatever ships your container logs ships
these too. Alert on the presence of `worker.crashed`, and on `worker.killed` by cause.

### Metrics collection

Poll `cell.metrics` on a schedule, for example with a [Yabeda](https://github.com/yabeda-rb/yabeda)
`collect` block. The control socket answers even while the work socket is saturated, and it is
host-local, so the poller must be a process on the cell's own host. Watch `queued`,
`queue_high_water`, `cancelled`, and `killed_by` cause.

### Per-call telemetry

Subscribe to the `perform.hot_cell` Active Support Notification for logging, metrics, or both. It
fires on every call, success or failure, and it is the only signal that survives a dead cell -- an
unreachable socket comes back as code `unavailable`, so the primary alarm belongs here.

### Container healthcheck

The installed Dockerfile wires `hotcell-health` up as the Docker `HEALTHCHECK`. It probes the
supervisor's control socket from inside the container, where `network: none` does not apply. Healthy
means the supervisor answers, not that a worker is free. If you're using your own container,
remember to use this.

### Rails healthcheck

Poll `describe` and `metrics` from an unauthenticated endpoint like `/up/hotcell`. The supervisor
answers both on the control socket without forking, so polling costs nothing.

A descriptor never crosses that socket, so both stay green on a cell whose work socket your application
cannot use. Only a round trip sees that: copy `examples/operations/echo.rb` and `reopen.rb` into the
cell, call both from a second authenticated endpoint, and check the bytes come back. A cell missing the
shared group answers `echo` perfectly and fails `reopen` with `EACCES`.

## Development

Working on the gems themselves is documented in [CONTRIBUTING.md](CONTRIBUTING.md): how the suites are split,
how a cell is exercised natively and in a container, and the rules that are not obvious from the code.

## Design

[docs/DESIGN.md](docs/DESIGN.md) holds what the code cannot tell you: the threat model, the invariants the
design exists to hold, why descriptors rather than a shared volume, and the facts that were measured rather
than reasoned about. Behavior is the code's to describe, and it does.

[adr/](adr/README.md) describes some decisions that we arrived at during development.
