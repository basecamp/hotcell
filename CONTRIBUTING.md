# Contributing to HotCell

This is a guide to working on the gems themselves. If you are building *on* HotCell — writing operations for
your own application — start with [README.md](README.md) instead.

## Setting up

```
bundle install
```

That is enough for the hotcell gems and for the example cell. It is deliberately enough: **the
hotcell gems need no container and no tool installed**, and `rake test:hotcell` is what keeps that honest —
CI runs it on a machine with nothing on it. Fixture operations stand in for the work, so the protocol, the
fork, the descriptor passing, the limits and the reap are all exercised in milliseconds.

Two things need more, and only when you touch them:

| To run | You need |
| --- | --- |
| `rake test:activestorage` | libvips, mutool, ffmpeg, ffprobe, ImageMagick, pdftoppm |
| `bin/conformance`, `bin/load` | Docker, and Linux |

## Running the tests

```
rake                        # everything, then rubocop
rake test:hotcell           # everything that needs no tool installed
rake test:activestorage     # everything that needs the converters installed
rake test:devcell           # boot the real development cell and run the example battery
rake test:gem:hotcell-core  # one gem's suite
rake rubocop                # style, one configuration for every gem
```

One file, or one test, from inside a gem directory:

```
cd hotcell-server
rake test TEST=test/slot_test.rb
rake test TEST=test/slot_test.rb TESTOPTS="-n/reuse/"
```

The container checks are scripts rather than rake tasks, because they need Docker and a built image:

```
bin/example-image           # install the cell scaffold and build what it wrote
bin/conformance IMAGE       # does this image support hotcell?
bin/load IMAGE [SCENARIO] [SECONDS] [THREADS]
```

## The layout

```
hotcell-core/                 the wire protocol, descriptors, failures — both sides depend on it
hotcell-client/               the application side, and the installer that scaffolds a cell
hotcell-server/               the supervisor, workers, slots, limits, and exe/hotcell
activestorage-hotcell-server/ the media operations
activestorage-hotcell-client/ the Rails transformer, analyzers and previewers

examples/                     one cell's worth of sample operations and the battery that drives them
bin/                          the container checks: example-image, conformance, load
docs/                         the design document, the deployment guide, the tuning guide
adr/                          decisions that were argued rather than obvious
```

## How a cell gets exercised

There are two sets of operations in this repository, and reaching for the wrong one is the easiest mistake
to make here.

**Fixture operations** — `HotCell::Fixtures` in `hotcell-server/lib/hot_cell/test_operations.rb`, named
`test.*`. These are for the minitest suites: forty-odd operations covering every edge the protocol has, from
`test.mojibake` to `test.early_idle`. They ship in the gem rather than sitting in its own test directory,
because `hotcell-client`'s suite boots a real cell and needs an inventory to point it at. If you are writing
a test for a gem, this is what you want.

**Example operations** — `examples/operations`, named `example.*`. These are for exercising a *whole cell*
from the outside, where the suite does not own the process: a development cell booted from `exe/hotcell`, or
somebody's container image. They double as worked examples of how to write an operation, so they stay few,
readable and pure Ruby with no external toolchain — which is also what lets them run on macOS, where the
converters and Docker are absent.

| op | behavior | what it proves |
| --- | --- | --- |
| `echo` | read the input fd, write it back to the output fd | descriptor passing round-trips; a throughput baseline |
| `sleep` | block for `seconds` | the deadline kills and answers; head-of-line behavior under load |
| `greedy` | allocate `megabytes` | the `memory` clamp → `killed: memory`, where enforceable |
| `overflow` | write `megabytes` to the output | the `file_size` clamp → `killed: fsize` |
| `crash` | raise, or die by signal | worker death → a clean verdict and continued service |
| `spawn` | start a grandchild that would outlive the worker | the group kill leaves nothing behind |
| `probe` | whether a pid is alive, asked from inside the cell | how `spawn` is watched, in any pid namespace |
| `isolation` | interfaces, root writability, scratch `noexec`, a tool's environment | the container-only checks, from the only place that can make them |

`examples/lib` holds the thin `HotCell::Client` classes that call them and the **battery** — one list of
checks built from those clients, so every consumer asks a cell the same questions. Consumers drive through
the client classes rather than a raw `Connection`, because that is what an application does, and the wrapper
costs little enough that load numbers still measure the cell.

Three consumers run that battery.

### `rake test:devcell` — does the development configuration work?

Boots the real `exe/hotcell` as a plain host process on the example operations, exactly the way you run it
yourself, runs the battery, then sends `SIGTERM` and asserts exit 0 with no socket left behind. It is part
of `rake test:hotcell`, so it runs with the rest of the suite, on Linux and macOS both.

It is Docker-free on purpose. See "Cells run uncontainerized in development" below.

### `bin/conformance IMAGE` — does this image support hotcell?

The real use case is somebody building their own cell image and wanting to know whether it works. It boots
`IMAGE` with the accessory's real flags — `network: none`, `cap-drop ALL`, a read-only root, a `noexec`
tmpfs — with `HOTCELL_DIR` pointed somewhere non-default, and asserts that the server starts, that the socket
appears where `HOTCELL_DIR` said it would, that the battery passes, and that the isolation holds. It exits
non-zero on the first failure, so it gates.

The driver runs in a **second container** over a shared volume, so a descriptor crossing the container
boundary is part of every check. That container is a stock Ruby image rather than the image under test, so a
minimal cell image never has to carry the client's dependencies.

The example operations are mounted over `/hotcell/operations`, shadowing whatever the image baked in. That is
deliberate: what is under test is the image's runtime — its Ruby, its gems, its user, and the flags — rather
than the work it does.

CI runs it against what `bin/example-image` builds. That script runs the installer and builds exactly what it
wrote, so the scaffold an application is actually given is the thing CI proves. Nothing derives from a
published base image, so the installed scaffold is the only kind of cell image there is.

### `bin/load IMAGE` — how does it behave under pressure?

The same operations at volume against a containerized cell. It reports throughput, latency split into
`queued_ms` against `perform_ms`, and the verdict breakdown, which is what tells saturation apart from
slowness. Scenarios: `echo` for a baseline, `sleep` for queueing, `greedy` and `overflow` for the resource
kills, `crash` for worker death, `spawn` for orphans, and `mix` for a weighted blend.

The cell's knobs pass through the environment, so finding a knee needs no edit:

```
EXAMPLE_CONCURRENCY=4 EXAMPLE_QUEUE_SIZE=16 bin/load hotcell:example echo 30 16
```

Heavy runs are manual. A short bounded run works as a CI gate if one is ever wanted.

## Rules that are not obvious

**Nothing loads libvips into a test process.** libvips creates its thread pool the first time it processes an
image, and that pool does not survive `fork`: a child forked afterwards waits forever for a worker thread
that does not exist. The Active Storage suites boot real cells by forking, so the operations load inside the
cell, the fixtures are generated by CLI tools, and `Cell.boot` refuses to fork a process that has libvips
loaded. `fork_safety_test.rb` holds both halves of that, because a test that only showed the good case would
not establish that the hazard is real.

The same rule is what `before_fork` and `before_worker_boot` exist for. A hook that evaluates an image in the
supervisor is a silent hang on every request afterwards, not a crash — see the comments on
`HotCell::Operation.before_fork`.

**Cells run uncontainerized in development**, on every platform, so there is one thing to document and one
thing to debug. The reason is macOS and it cannot be engineered around: Docker Desktop runs containers in a
Linux VM, a file descriptor is an index into one kernel's table, and `sendmsg` has nothing meaningful to hand
across two kernels. Native `AF_UNIX` and `SCM_RIGHTS` on macOS are fine; it is the host-to-VM boundary that
cannot carry a descriptor. That is why `rake test:devcell` exists and why it uses no Docker, and what it
leaves out — the isolation — is what `bin/conformance` covers on Linux.

**macOS has no finite `RLIMIT_DATA`.** `Process.setrlimit` rejects one with `EINVAL`, so a cell there runs
with its memory clamp unenforced and says so once, on `$stderr`. Tests that assert the clamp skip themselves
where it cannot be set; a new one that asserts memory behaviour has to do the same. Every other limit is
strict on both platforms.

**Testing a control.** Security controls here fail silently, so a test that would still pass with the control
removed is worse than no test: it reads as assurance. Every control is covered by a test that observes the
behaviour the control produces, rather than by an assertion that the control is written down —
`unsetenv_others: true` is proved by setting a variable, running a tool, and finding that the tool never saw
it. Where a control has no reachable trigger and so cannot be tested, it says so where it lives.

**A verdict that cannot be taken back needs a reason.** `permanent` means an application may write a failure
down against a blob and serve it from a cache forever, so anything unclassified is transient by default.
`hotcell-core/lib/hot_cell/codes.rb` carries the argument for each code; a new code goes in that table, and a
new kill reason goes in `PERMANENT_BY_CAUSE`, or it silently becomes the wrong kind of permanent.

## Style

```
rake rubocop
```

One configuration for every gem, because the style is one style. It runs in CI as its own job.

## Writing it down

[docs/DESIGN.md](docs/DESIGN.md) holds the threat model, the numbered invariants, and the facts that were
established by experiment rather than by reasoning — the fork hazard, what `RLIMIT_DATA` charges, what
`/proc` gives a sibling away. Read it before changing anything a limit or an isolation claim rests on. It
deliberately does not describe behavior: that is the code's job, and a duplicate description rots.

The invariants are numbered, and code comments across three gems cite them by number. Do not renumber them.

[adr/](adr/README.md) holds the decisions that were argued rather than obvious, so the argument does not have
to be rerun. Write one when a decision cost you a real debate; do not edit one afterwards — a later decision
that changes it gets its own record.

Comments in this codebase carry the reasoning, not the mechanics. A comment that restates the line below it
is noise; a comment that says why the obvious version does not work is the whole value. Match what is
already there.

## CI

| Job | Runs |
| --- | --- |
| `hotcell (ruby …)` | `rake test:hotcell` on 3.3, 3.4, 4.0 and head, on a machine with no tools |
| `hotcell (macos, ruby 3.4)` | the same, on macOS — advisory, because the runners are slow and bill about ten times the Linux rate |
| `activestorage (ruby …)` | `rake test:activestorage` with the converters installed |
| `container conformance` | `bin/example-image` then `bin/conformance` |
| `Style` | `rubocop` |
| `GitHub Actions audit` | actionlint and zizmor |

Actions are pinned to SHAs and the workflow has no default permissions. `zizmor` will tell you if a change
breaks either.
