![hotcell-logo](docs/hotcell-logo.png)

# Hot Cell

Securely run untrusted code on untrusted inputs. Hot Cell moves that work out of your application and into
an unprivileged sibling container: no network, no credentials, and nothing on its filesystem worth
stealing.

Inputs and outputs travel as file descriptors over a UNIX socket on a shared volume. Each call is a remote
procedure call (RPC): your application calls an ordinary Ruby method. Hot Cell forwards the arguments to the container, runs the work in a forked
worker process under strict limits, and returns the result or writes it to the output file.

## Status

This is pre-release software. It may break in interesting ways. Use it with caution until the v1.0
release.

The Active Storage gems need Rails 8.2, which is unreleased. Track `rails/rails` `main` until it ships.
See [Active Storage operations](docs/active-storage.md).

## Why would I use this?

Your Rails application accepts uploads, so somewhere in it there's a line like this:

```ruby
blob.variant(resize_to_limit: [ 800, 600 ]).processed
```

An attacker just handed you a crafted file, and Rails is about to hand it to libvips: a few hundred
thousand lines of C whose whole job is to guess at file formats and delegate them to other format-specific
libraries that you may not know about. libvips, ImageMagick, ffmpeg, and LibreOffice all have long
histories of memory-safety bugs, and by default each one runs in the container that holds your database
credentials, your session secret, and a route to every network service that the app uses.

Hot Cell gives that work its own container and its own forked process, holding nothing an attacker wants.
Remove libvips and ffmpeg from your application image and keep them in the cell. Code execution there
gets an attacker a read-only input descriptor, a write-only output descriptor, and the scratch of whatever
else the cell is converting. The blast radius is much smaller than if that attack succeeded in your
application code.

For Rails, Hot Cell ships drop-in replacements for the Active Storage analyzers, transformers, and
previewers, so adopting it takes configuration changes, not code changes. In our environment, Hot Cell adds
about 8 milliseconds per call and one more container on each host. We think that's a very good trade for
the improved security posture.

Hot Cell isn't limited to media conversion:

- You can configure several cells on each host.
- A call can pass several input and output files.
- Custom operations have a simple `#perform` API, like Active Job's.
- Cell limits are configurable: memory, wall-clock time, disk usage, and more.
- You can bring your own container image, checked by the included conformance test.
- You can set how often workers are forked again, to trade isolation for performance.

So you could use Hot Cell for ZIP files, or for compute that might hog the CPU. If something puts your
trusted application at risk, move it into a cell.

## The gems

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both sides | The wire protocol, descriptor passing, payload validation, and the error taxonomy. |
| `hotcell-client` | the application | `HotCell::Client`, cell registration, routing, classification, and instrumentation. |
| `hotcell-server` | the cell | The supervisor, the worker, `HotCell::Operation`, and the container image. |
| `activestorage-hotcell-client` | the application | The transformers, analyzers, and previewers that Rails is configured with. |
| `activestorage-hotcell-server` | the cell | The Active Storage operations. |
| `yabeda-hotcell` | the application | Yabeda metrics for every call and for each local cell. |

The gems are in one repository because they're developed together. The Active Storage gems may move to
another repository later.

## Using the Active Storage operations

This section runs Active Storage's variants, analysis, and previews in a cell. Your application code
doesn't change, but you deploy a second container beside the application: a Kamal accessory, or your
infrastructure's equivalent sidecar.

The examples use libvips, mutool, and ffmpeg. If your application uses `variant_processor = :magick`,
use the `Magick` classes instead of the `Vips` classes. See
[Active Storage operations](docs/active-storage.md#classes).

### 1. Install

Add the client gem to the application:

```ruby
# Gemfile -- the application
gem "activestorage-hotcell-client"
```

Run `bin/rails hotcell:install`. It creates a `hotcell/` directory in the application root that holds
everything about the cell, separate from the client configuration and the application code:

- `hotcell/Gemfile`: the gems that the operations need.
- `hotcell/Dockerfile`: the recipe for the cell's image.
- `hotcell/config.rb`: the cell's own settings.
- `hotcell/operations/`: the Ruby files that the cell loads at boot.

Add the server gem to the cell's `Gemfile`, and require the operations that match the classes that the
application uses. Requiring an operation's file is what makes the cell serve it.

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

### 2. Configure the application

Register the cell in an initializer, with one of your exception classes for permanent failures and one
for transient failures:

```ruby
# config/initializers/hotcell.rb
HotCell.root  = ENV["HOTCELL_ROOT"]  # unset means every cell is off
HotCell.group = ENV["HOTCELL_GROUP"] # the gid shared between app and cell

HotCell.register "active_storage",
  permanent: MyApp::UnprocessableUpload,
  transient: MyApp::ConversionTemporarilyUnavailable

# Warns at boot about a cell that is unreachable, slower than this client waits, in the wrong group, or on another hotcell version.
Rails.application.config.after_initialize { HotCell.describe_cells }
```

The cell's sockets are in `$HOTCELL_ROOT/active_storage`. If `HOTCELL_ROOT` is unset, every variant,
analysis, and preview raises `HotCell::CellNotConfigured` rather than falling back to the application. See
[Client API](docs/client-api.md) and [Response codes](docs/codes.md).

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

For every class that you name, the cell must load the matching operation, and the cell's image must
install the library or tool. You can mix these classes with Rails' own. See
[Active Storage operations](docs/active-storage.md).

### 3. Run it in development

Run the cell as a plain process, managed by foreman beside the Rails server. A containerized cell works
only on Linux, because descriptor passing doesn't cross the VM that runs containers on macOS. The resource
limits and the deadline apply either way. The cell keeps its own bundle, from the same `hotcell/Gemfile`
that the image build copies, so the two sides stay separate in development as they are in production.

Add the cell to `Procfile.dev`:

```procfile
web: HOTCELL_ROOT=$PWD/tmp/hotcell-sockets bin/rails server
cell: BUNDLE_GEMFILE=$PWD/hotcell/Gemfile HOTCELL_CONFIG=$PWD/hotcell/config.rb HOTCELL_OPERATIONS=$PWD/hotcell/operations HOTCELL_DIR=$PWD/tmp/hotcell-sockets/active_storage bundle exec hotcell --development
```

`bin/dev` then boots both, and the app finds the sockets under `tmp/hotcell-sockets`. Keep
`--development`: without it, the cell empties the system temporary directory at boot. See
[Development mode](docs/cell-settings.md#development-mode).

### 4. Set the cell's limits

Declare the cell's limits in `hotcell/config.rb`:

```ruby
# hotcell/config.rb
HotCell.limits concurrency: 4, queue_size: 8, deadline: 60, memory: 1536 * 1024**2
```

Each operation declares its own limits, and the cell clamps them to its own. See
[Cell settings](docs/cell-settings.md) for every setting and [Tuning](docs/tuning.md) for how to choose
the numbers.

### 5. Build and deploy the cell

Hot Cell publishes no base image. Customize the installed `Dockerfile` for your application, starting with
the system packages that your operations need:

```dockerfile
# hotcell/Dockerfile (excerpt)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libvips42 mupdf-tools ffmpeg && \
    rm -rf /var/lib/apt/lists/*
```

Match the `OMP_NUM_THREADS` that the `Dockerfile` sets to the container's `cpus`. Without that bound, a
cell on a large host dies. See [Bound the OpenMP thread pools](docs/container.md#bound-the-openmp-thread-pools).

Build the image from the `hotcell/` directory, and deploy it as a second container on the same host as the
application, sharing one volume for the sockets. With Kamal, that's one accessory for each cell:

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

The application mounts the same volume:

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

The two mount paths differ, and only the volume name must match: a cell writes its sockets to
`HOTCELL_DIR`, and the app finds a cell by name under `HOTCELL_ROOT`. Give each cell its own volume.

[Container](docs/container.md) explains every flag and how to check a deployed accessory.
[Scratch](docs/scratch.md) covers moving scratch off the tmpfs. If your image installs ImageMagick, set
its limits too. See [ImageMagick](docs/imagemagick.md).

### 6. Remove the packages from the application image

After the cell handles a file type, remove that type's packages, such as libvips, from the application
image. That removal is the security improvement.

Don't remove a package before the cell handles its file type. Rails' own previewers and analyzers look for
their tool in `accept?`, so a package removed too early turns that processing off without an error.

## Using custom operations

The `hotcell/` directory, the limits, the container, and the deployment all stay the same. You write both
sides of the call.

In the application, a client names its cell and the operation's routing name:

```ruby
class TransformImage < HotCell::Client
  hotcell "images"
  operation "images.transform"
end

result = TransformImage.perform_in_hotcell source, destination, format: "png"
```

In the cell, an operation answers to the same name, and `perform` receives the descriptors and the
payload as keyword arguments:

```ruby
class TransformImageOperation < HotCell::Operation
  operation "images.transform"
  limits deadline: 30, memory: 1280 * 1024**2

  before_fork { require "my_image_processor" }

  def perform(inputs, outputs, format:)
    MyImageProcessor.convert inputs.first.fd_path, outputs.first.fd_path, format: format
    { format: format }
  end
end
```

Register the `images` cell in the application's initializer, as in
[Configure the application](#2-configure-the-application). The cell's `Gemfile` names `hotcell-server`
directly, plus whatever gems the operation uses. Put the operation's file in `hotcell/operations/`, and
install the tools that it runs in the `Dockerfile`. `config.rb` doesn't change: the operation's own
`limits` come with its class, clamped to the cell's.

[Operation API](docs/operation-api.md) and [Client API](docs/client-api.md) cover the rest.

## Running Hot Cell in production

Set these alerts. [Observability](docs/observability.md) explains each signal.

- **Cell availability:** the `up` gauge is 0 or absent for any cell on any host.
- **Failed calls:** the `requests` counter shifts away from `ok`, especially toward `unavailable`.
- **Queue headroom:** `queued` nears `queue_size`, `queue_high_water` rises, or `capacity` appears in
  steady state.
- **Scratch space:** free space on each host's scratch runs low.
- **Cell errors:** any `ERROR` event in the cell log, or a rise in the `killed` gauge.

## Documentation

The [reference manual](docs/index.md) describes every part of Hot Cell, one topic per page. It's written
for agents and for readers who want the details.

The [design pages](docs/design/index.md) hold what the code can't tell you: the threat model, the
invariants that the design exists to hold.

[Contributing to Hot Cell](docs/contributing/index.md) covers working on the gems themselves, the facts that were
measured rather than reasoned about, and the decisions that were argued rather than obvious.
