# Deploying a cell

A cell is a second container beside the application, on the same host, sharing one volume that holds its
UNIX sockets. The README carries the complete Kamal configuration for both halves, under
[Configure and deploy the HotCell container](../README.md#configure-and-deploy-the-hotcell-container).

This document explains that configuration: how the image is built, what every flag and setting does,
how the numbers constrain each other, and one alternative worth knowing about. The examples use Kamal;
any orchestrator that can set the same `docker run` flags will do.

[docs/TUNING.md](TUNING.md) is a companion document. It covers measuring your way to values for your
own workload, where this one covers what the values mean.

## Building an image

### Using the installed Dockerfile

There is no published base image to derive from. `bin/rails hotcell:install` writes a `hotcell/`
directory into the application holding a complete `Dockerfile`, the cell's `Gemfile`, its
`config.rb`, and an `operations/` directory. That Dockerfile is the whole recipe, and it is yours to
customize. Build it from its own directory:

```
docker build -t your-image:latest hotcell/
```

The README's [Configure and deploy the HotCell
container](../README.md#configure-and-deploy-the-hotcell-container) walks through the mechanical
edits, but here are some additional tips:

**Every gem is inside the blast radius.** Keep the cell's `Gemfile` short. A larger supervisor heap also
costs every request — see "Sizing the numbers".

**Load only the operations your image has tools for.** A cell advertises what it loaded, on `describe`,
and a client checks that inventory at boot to catch a cell that does not carry the operation it wants. An
operation whose tool is missing makes that check pass and fails at the first request instead. So requiring
an operation you did not install a tool for is worse than not requiring it.

**The cell's image must create its own socket mount point**, owned by the cell's user — `/run/hotcell/cell`
and not only `/run/hotcell`. Docker creates a missing last level as root, and the cell then cannot create a
socket in it. The installed Dockerfile does this. The application's image needs nothing at its own mount
point.

**Keep the app's and the cell's lockfiles in step.** They resolve hotcell separately.
`HotCell.describe_cells` warns at boot when the cell's `hotcell-server` version differs from the app's
`hotcell-client` version.

## Container settings

These are `docker run` flags. Under Kamal they go in an accessory's `options:`, and Kamal supplies no
value of its own for any of them.

`network` is the one exception, and it is the flag this design depends on most. It is an accessory key of
its own, a sibling of `image:` and `roles:`. Kamal always emits a `--network` of its own, `kamal` by
default. An entry under `options:` adds a second `--network` rather than replacing the first, and Docker
refuses the container:

```
docker: conflicting options: cannot attach both user-defined and non-user-defined network-modes
```

The complete accessory, both halves, is in the README under
[Configure and deploy the HotCell container](../README.md#configure-and-deploy-the-hotcell-container).
Copy it from there. The tables below say what each flag does and how to size it.

Give each cell its own volume. Two accessories sharing one would write `work.sock` over each other.

### Performance

**These have no defaults.** Docker applies no limit to a flag you omit, so a cell without them can take
the whole host. Tune each one to your workload and your hardware. The values below are the worked example
from the README's accessory, not recommendations.

| Flag | Example | Tune it from |
| --- | --- | --- |
| `cpus` | `2` | The share of the host this cell may use. Start the cell's `concurrency` at twice this number, and match the image's `OMP_NUM_THREADS` to it — see "Bound the OpenMP thread pools". |
| `memory` | `2g` | The cgroup limit, counting every worker and the tmpfs. Size it from `concurrency × peak RSS` plus the tmpfs. Keep it above the cell's `memory`. On a disk-backed scratch there is no tmpfs term — see "Where scratch lives". |
| `memory-swap` | `2g` | Set it equal to `memory`. Omit it and Docker allows twice `memory` in swap, so the memory limit no longer holds. |
| `tmpfs` size | `size=512m` | Scratch for all concurrent workers together. It pairs with `file_size × concurrency`. Moving scratch onto disk decouples it from `memory` — see "Where scratch lives". |
| `ulimit: stack` | leave it unset | A container inherits the Docker daemon's value, normally 8MB, and that is where to leave it. Lowering it buys a worker about 24MB more room at 2MB, and nothing at all for an operation that shells out. It costs far more than it buys: a thread that overflows the smaller stack dies on `SIGSEGV`, and the cell reports that as `killed`/`crashed`, which is transient — so the request is retried against a limit that will fail it again for as long as the caller's job keeps trying, and nothing in the verdict points at the setting that caused it. Raise the cell's `memory` instead. It belongs here rather than in `config.rb` because glibc reads it at exec, before `Process.setrlimit` could run. |

### Security

**Use these values.** They are what a cell is for. Omit one and the protection is gone, while the cell
serves requests exactly as before.

| Flag | Recommended | What it does |
| --- | --- | --- |
| `network` | `none` | Removes every network interface. A tool that is persuaded to fetch a URL cannot reach anything. Set it as an accessory key, not under `options:`. |
| `read-only` | `true` | Makes the root filesystem read-only. A cell writes only to `/tmp` and to the socket volume. |
| `tmpfs` flags | `nosuid,nodev,noexec` | `noexec` stops a dropped binary running from `/tmp`, which is where a request's files live. It does not cover the socket volume, and it does not stop `ruby payload.rb`. On a disk-backed scratch Docker sets none of them — see "Where scratch lives". |
| `cap-drop` | `ALL` | Removes every Linux capability. |
| `security-opt` | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | `10001:10001` | Runs the cell with no home directory and no shell. Without user namespace remapping this is a host uid, and it is inside the ordinary range, so pick one your hosts do not give to a person. |
| `pids-limit` | `512` | Bounds the number of processes in the cell. It must clear `concurrency` plus the threads and subprocesses one toolchain starts, so check it when you raise `concurrency`. |

### Bound the OpenMP thread pools

**Set `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` in the image.** The installed `Dockerfile` sets both, and
on a large host neither is optional: without them a cell dies there. `hotcell:install` leaves an existing
`Dockerfile` untouched, so add both by hand to a cell installed before this and rebuild its image.

OpenMP sizes its thread pool from the host's core count, and a `cpus:` limit is a CFS quota rather than an
affinity mask, so it does not lower that count — on a 98-core host libvips and ImageMagick ask for 98
threads. Each thread stack is 8MB of private anonymous memory, which the cell's `memory` charges as
`RLIMIT_DATA`: under a 1280MB limit, 96 of those stacks fit and 104 do not. Past that line `pthread_create` returns `EAGAIN`, which libgomp treats as unrecoverable — it writes

```
libgomp: Thread creation failed: Resource temporarily unavailable
```

to stderr and calls `exit(1)`. The worker dies before answering, so the caller gets a transient failure and
the job retries it against a host that fails the same way. This killed 285 Basecamp workers in production
on 2026-08-31 and forced a rollback.

That line reaches a log now: the supervisor captures what a worker writes to fd 2 and attaches its tail to
the `worker.killed` that reports its death, as `hotcell.stderr`, and to the failure the caller receives. See
`docs/LOGS.md`.

**Size `OMP_NUM_THREADS` from the container's `cpus`:** the number follows the allocation, not the example
above. It is a thread count, so round a fractional quota down, and up to 1 below that. `OMP_THREAD_LIMIT` is the backstop against a library that raises the count itself by calling
`omp_set_num_threads`, which is what ImageMagick does for `MAGICK_THREAD_LIMIT`.

**The cell forwards the bound to the tools it execs.** A tool sees the environment its operation wrote for
it rather than the worker's own, which is invariant 9, so the image's variables alone would bound
in-process libvips and nothing else. `Operation#run_tool` and mini_magick both carry the pair from the
cell's environment.

**A deploy to staging or beta cannot catch a regression here.** The failure exists only at production's
core count — which is how it reached production. So the guard is a test:
`hotcell-client/test/install_test.rb` holds the scaffold's variables, and an image you customize needs its
own.

To verify a built image, write a GIF inside it and count `/proc/self/task` during the write. GIF is the
cheapest probe: it is the only common output format that quantizes, and quantization is where the threads
appear. Unbounded, the count tracks the visible cores; bounded, it stays at the limit.

#### Verifying your accessory

`bin/conformance` supplies its own docker flags, so it proves the image works when the flags are right.
It doesn't read your Kamal configuration, and it passes against an image you are about to deploy with
`cap-drop` missing.

To check your accessory before you deploy it, print the command Kamal will run. `kamal config` does not
answer this. It prints merged configuration, not the command, so a `--network` emitted twice does not
appear there at all.

```
bundle exec ruby -rkamal -e '
  config = Kamal::Configuration.create_from(
    config_file: Pathname.new("config/deploy.yml"), destination: "production", version: "check")
  puts Kamal::Commands::Accessory.new(config, name: :images).run.flatten.join(" ")
'
```

Read `--network` off that line. It must appear once, as `--network none`. Two of them is the `options:`
mistake described under "Container settings", and Docker rejects the container at boot with exit
status 125.

To check a deployed cell, read the flags on the running container:

```
docker inspect <container> --format '{{json .HostConfig}}' | jq '{
  NetworkMode, ReadonlyRootfs, CapDrop, SecurityOpt, PidsLimit, Memory, MemorySwap, Tmpfs, Binds
}'
```
