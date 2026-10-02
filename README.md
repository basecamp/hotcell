![hotcell-logo](docs/hotcell-logo.png)

# HotCell

Securely run untrusted code on untrusted inputs. HotCell lets you move that work out of your application
and into an unprivileged sibling container: no network, no credentials, and nothing on its filesystem
worth stealing.

Inputs and outputs travel as file descriptors over a UNIX socket on a shared volume. Each call is a
remote procedure call ("RPC"): your application calls an ordinary Ruby method, the arguments are
forwarded to the container where the work runs in a forked worker process with strict limits
applied, and the results are returned or written to the output file.

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
| `yabeda-hotcell` | the application | Yabeda metrics for every call and for each local cell's counters. |

They are in one repository because they are being developed together today. We may split out the
Active Storage gems into another repository at a later date.

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

# Quick health check at boot. Warns about a cell that is unreachable, slower than this client waits, in the wrong group, or on another hotcell version.
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
cell: BUNDLE_GEMFILE=$PWD/hotcell/Gemfile HOTCELL_CONFIG=$PWD/hotcell/config.rb HOTCELL_OPERATIONS=$PWD/hotcell/operations HOTCELL_DIR=$PWD/tmp/hotcell-sockets/active_storage bundle exec hotcell --development
```

Then `bin/dev` boots both, and the app finds the sockets under `tmp/hotcell-sockets`. At boot the cell
empties its `TMPDIR` of every entry its uid owns, and told none it empties the system temporary directory.
On a developer's machine that is `/tmp`, or on macOS the per-user `TMPDIR` every shell sets, both shared
with everything else the developer runs. With `--development` the cell never sweeps the directory it is
given: its scratch is `hotcell-<HOTCELL_DIR with slashes as dashes>` beneath it. `HOTCELL_WORKSPACE`
defaults under the scratch; pointed elsewhere, its parent is swept too.

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

Match the `OMP_NUM_THREADS` the installed `Dockerfile` sets to the container's `cpus` below. OpenMP
reads the host's core count, which a `cpus` quota does not lower, so an unbounded libvips or ImageMagick
asks a large host for one 8MB thread stack per core and dies on its own memory limit -- see
[Bound the OpenMP thread pools](docs/DEPLOYMENT.md#bound-the-openmp-thread-pools).

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
[docs/IMAGEMAGICK.md](docs/IMAGEMAGICK.md) covers ImageMagick's own resource limits, which an image that
installs it must size from the same numbers.

### Using custom operations

Everything above still applies: the same `hotcell/` directory, the same limits, the same container,
the same deployment. What changes is that you write both sides of the call yourself.

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

## Development

Working on the gems themselves is documented in [CONTRIBUTING.md](CONTRIBUTING.md): how the suites are split,
how a cell is exercised natively and in a container, and the rules that are not obvious from the code.

## Design

[docs/DESIGN.md](docs/DESIGN.md) holds what the code cannot tell you: the threat model, the invariants the
design exists to hold, why descriptors rather than a shared volume, and the facts that were measured rather
than reasoned about. Behavior is the code's to describe, and it does.

[adr/](adr/README.md) describes some decisions that we arrived at during development.
