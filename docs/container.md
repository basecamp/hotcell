---
type: Reference
title: "Container"
order: 6
description: "Building the cell's image, every container flag and what it does, bounding OpenMP, and checking an accessory before and after a deploy."
sources:
  - hotcell-client/lib/hot_cell/install
  - hotcell-client/test/install_test.rb
  - bin/conformance
---

# Container

This page describes the cell's container: how to build its image, what each container flag does, how to
bound OpenMP, and how to check an accessory before and after you deploy it.

A cell is a second container beside the application, on the same host, that shares one volume holding its
UNIX sockets. The examples use Kamal. Any orchestrator that can set the same `docker run` flags works. The
complete Kamal configuration for both containers is in the README, under
[Build and deploy the cell](../README.md#5-build-and-deploy-the-cell).

For the settings inside the cell, see [Cell settings](cell-settings.md). For how the numbers constrain
each other, see [Tuning](tuning.md). For where scratch lives, see [Scratch](scratch.md). To test an image
that you built yourself, see [Conformance](conformance.md).

## Build an image

Hot Cell publishes no base image. `bin/rails hotcell:install` writes a `hotcell/` directory into the
application that holds a complete `Dockerfile`, the cell's `Gemfile`, its `config.rb`, and an
`operations/` directory. That `Dockerfile` is the whole recipe, and you can customize it. Build it from
its own directory:

```
docker build -t your-image:latest hotcell/
```

Keep the following in mind:

- **Every gem is inside the blast radius.** Keep the cell's `Gemfile` short. A larger supervisor heap also
  costs every request. See [Tuning](tuning.md#sizing-guidelines).
- **Load only the operations that your image has tools for.** A cell reports what it loaded in `describe`,
  and a client checks that inventory at boot to catch a cell that doesn't carry an operation that it
  wants. An operation whose tool is missing passes that check and fails at the first request instead. So
  requiring an operation without installing its tool is worse than not requiring it.
- **The cell's image must create its own socket mount point**, owned by the cell's user:
  `/run/hotcell/cell`, not only `/run/hotcell`. Docker creates a missing last level as root, and the cell
  then can't create a socket in it. The installed `Dockerfile` does this. The application's image needs
  nothing at its own mount point.
- **Keep the application's and the cell's lockfiles in step.** They resolve Hot Cell separately.
  `HotCell.describe_cells` warns at boot when the cell's `hotcell-server` version differs from the
  application's `hotcell-client` version.

## Container flags

These are `docker run` flags. Under Kamal, they go in an accessory's `options:`, and Kamal supplies no
value of its own for any of them.

`network` is the exception, and it's the flag that the design depends on most. It's an accessory key of
its own, a sibling of `image:` and `roles:`. Kamal always emits its own `--network`, `kamal` by default.
An entry under `options:` adds a second `--network` rather than replacing the first, and Docker refuses
the container:

```
docker: conflicting options: cannot attach both user-defined and non-user-defined network-modes
```

Give each cell its own socket volume. Two accessories that share one would write `work.sock` over each
other.

Without Kamal, the cell container needs `--volume hotcell-sockets:/run/hotcell/cell` and the security flags
below. The application container needs `--volume hotcell-sockets:/run/hotcell/active_storage`,
`--group-add 10001`, and `HOTCELL_ROOT=/run/hotcell`.

### Performance flags

These flags have no defaults: Docker applies no limit for a flag that you omit, so a cell without them can
take the whole host. Tune each one to your workload and your hardware. The examples are from the README's
accessory, and they aren't recommendations.

| Flag | Example | Description |
| --- | --- | --- |
| `cpus` | `2` | The share of the host that this cell can use. Start the cell's `concurrency` at twice this number, and match the image's `OMP_NUM_THREADS` to it. See [Bound the OpenMP thread pools](#bound-the-openmp-thread-pools). |
| `memory` | `2g` | The cgroup limit, which counts every worker and the tmpfs. Size it from `concurrency × peak RSS` plus the tmpfs. Keep it above the cell's `memory`. On a disk-backed scratch, there's no tmpfs term. See [Scratch](scratch.md). |
| `memory-swap` | `2g` | Set it equal to `memory`. If you omit it, Docker allows twice `memory` in swap, and the memory limit no longer holds. |
| `tmpfs` size | `size=512m` | Scratch for all concurrent workers together. Size it from `concurrency` times the most scratch that one request holds. See [Constraints between the numbers](tuning.md#constraints-between-the-numbers). Moving scratch onto disk separates it from `memory`. See [Scratch](scratch.md). |
| `ulimit: stack` | leave it unset | See [Don't lower the stack limit](#dont-lower-the-stack-limit). |

### Security flags

Use these values. They're what a cell is for. If you omit one, the protection is gone, and the cell still
serves requests exactly as before.

| Flag | Recommended | Description |
| --- | --- | --- |
| `network` | `none` | Removes every network interface. A tool that's persuaded to fetch a URL can't reach anything. Set it as an accessory key, not under `options:`. |
| `read-only` | `true` | Makes the root filesystem read-only. A cell writes only to `/tmp` and to the socket volume. |
| `tmpfs` flags | `nosuid,nodev,noexec` | `noexec` stops a dropped binary from running from `/tmp`, where a request's files live. It doesn't cover the socket volume, and it doesn't stop `ruby payload.rb`. On a disk-backed scratch, Docker sets none of these flags. See [Scratch](scratch.md). |
| `cap-drop` | `ALL` | Removes every Linux capability. |
| `security-opt` | `no-new-privileges:true` | Prevents a setuid binary from regaining what `cap-drop` removed. |
| `user` | `10001:10001` | Runs the cell with no home directory and no shell. Without user namespace remapping, this is a host uid in the ordinary range, so pick one that your hosts don't give to a person. |
| `pids-limit` | `512` | Bounds the number of processes in the cell. It must clear `concurrency` plus the threads and subprocesses that one toolchain starts, so check it when you raise `concurrency`. |

### Don't lower the stack limit

Leave `ulimit: stack` unset. A container inherits the Docker daemon's value, normally 8MB.

Lowering it to 2MB buys a worker about 24MB more room, and nothing for an operation that shells out. It
costs far more than that: a thread that overflows the smaller stack dies on `SIGSEGV`, and the cell
reports that as `killed` with cause `crashed`, which is transient. The caller's job retries the request
against a limit that fails it again, for as long as the job keeps trying, and nothing in the verdict
points at the setting. Raise the cell's `memory` instead.

The stack limit is a container flag rather than a `config.rb` setting because glibc reads it at exec,
before `Process.setrlimit` could run. `bin/conformance` and `bin/load` set no stack limit, and
`examples/gate` checks that they don't.

## Bound the OpenMP thread pools

Set `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` in the image. The installed `Dockerfile` sets both. On a large
host, neither is optional: without them, a cell dies. `hotcell:install` doesn't change an existing
`Dockerfile`, so for a cell installed before these variables existed, add both by hand and rebuild the
image.

OpenMP sizes its thread pool from the host's core count. A `cpus:` limit is a CFS quota, not an affinity
mask, so it doesn't lower that count: on a 98-core host, libvips and ImageMagick ask for 98 threads. Each
thread stack is 8MB of private anonymous memory, which the cell's `memory` limit charges as
`RLIMIT_DATA`. Under a 1280MB limit, 96 of those stacks fit and 104 don't. Past that line,
`pthread_create` returns `EAGAIN`, which libgomp treats as unrecoverable. It writes the following line to
standard error and calls `exit(1)`:

```
libgomp: Thread creation failed: Resource temporarily unavailable
```

The worker dies before it answers, so the caller gets a transient failure, and the job retries against a
host that fails the same way. This killed 285 Basecamp workers in production on 2026-08-31 and forced a
rollback.

That line now reaches a log. The supervisor captures what a worker writes to fd 2 and attaches its tail to
the `worker.killed` event, as `hotcell.stderr`, and to the failure that the caller receives. See
[What a worker wrote to fd 2](observability.md#what-a-worker-wrote-to-fd-2).

Size `OMP_NUM_THREADS` from the container's `cpus`. The number follows the allocation, not the example. It's
a thread count, so round a fractional quota down, and round a value below 1 up to 1. `OMP_THREAD_LIMIT` is
the backstop against a library that raises the count itself by calling `omp_set_num_threads`, which is
what ImageMagick does for `MAGICK_THREAD_LIMIT`.

The cell forwards both variables to the tools that it runs. A tool sees the environment that its
operation wrote for it, not the worker's own, which is [invariant 9](design/invariants.md). So the image's
variables alone would bound in-process libvips and nothing else. `Operation#run_tool` and mini_magick both
pass the pair from the cell's environment.

A deploy to staging or beta can't catch a regression here, because the failure exists only at
production's core count. That's how it reached production. So the guard is a test:
`hotcell-client/test/install_test.rb` checks the installed `Dockerfile`'s variables, and an image that you
customize needs its own test.

To verify a built image, write a GIF inside it and count `/proc/self/task` during the write. GIF is the
cheapest probe: it's the only common output format that quantizes, and quantization is where the threads
appear. Unbounded, the count tracks the visible cores. Bounded, it stays at the limit.

## Verify an accessory

`bin/conformance` supplies its own Docker flags, so it proves that the image works when the flags are
right. It doesn't read your Kamal configuration, and it passes against an image that you're about to
deploy with `cap-drop` missing.

### Before you deploy

Print the command that Kamal runs. `kamal config` doesn't show it: it prints the merged configuration, not
the command, so a `--network` emitted twice doesn't appear there at all.

```
bundle exec ruby -rkamal -e '
  config = Kamal::Configuration.create_from(
    config_file: Pathname.new("config/deploy.yml"), destination: "production", version: "check")
  puts Kamal::Commands::Accessory.new(config, name: :images).run.flatten.join(" ")
'
```

`--network` must appear once on that line, as `--network none`. Two of them is the `options:` mistake
described under [Container flags](#container-flags), and Docker rejects the container at boot with exit
status 125.

### After you deploy

Read the flags on the running container:

```
docker inspect <container> --format '{{json .HostConfig}}' | jq '{
  NetworkMode, ReadonlyRootfs, CapDrop, SecurityOpt, PidsLimit, Memory, MemorySwap, Tmpfs, Binds
}'
```
