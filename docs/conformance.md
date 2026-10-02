# Conformance

This page describes `bin/conformance`, which checks whether a container image can run a cell, and what it
can't check. Use it when you build your own image instead of the one that `hotcell:install` writes.

## Run the conformance checks

```
docker build -t my-cell:test hotcell/
bin/conformance my-cell:test
```

`bin/conformance IMAGE` does the following:

1. Boots the image with the flags in [Container flags](container.md#container-flags).
2. Mounts the example operations over `/hotcell/operations`.
3. Runs a battery of checks from a second container over a shared volume: descriptor round trips, each
   kill verdict, refusal at capacity, and the isolation flags.
4. Runs the same battery again against the image booted without one security flag at a time, and requires
   each run to fail at that flag's own check.

It exits non-zero on the first failed check.

The negative runs make the isolation results a test of the flags rather than a restatement of them: a
check that can't see a flag would pass a cell running without it. A runtime that force-mounts `noexec`
onto every tmpfs, as Docker Desktop does, can't host the `noexec` negative, and that one run reports
`SKIP` with the reason.

The mount hides the operations that your image carries. The checks cover the image's runtime (its Ruby,
its gems, and its socket behavior), not the work that your operations do.

`bin/example-image` builds an image to try it against. CI runs both on every push.

## What conformance can't check

### `kernel.yama.ptrace_scope`

The host must set `kernel.yama.ptrace_scope` to 1 or higher. No container flag can set it, and it's what
stops one worker from reading another request's memory through `/proc/<pid>/mem`. A cell refuses to boot
below it:

```
kernel.yama.ptrace_scope is 0 on this host, so one worker can read another request's memory
through /proc/<pid>/mem. No container flag can set it. Set it to 1 or higher and boot again.
```

A host that doesn't expose the file at all logs `cell.ptrace_scope_unknown` and boots anyway. See
[Worker isolation](design/worker-isolation.md).

### Some security flags

Conformance reads these flags from inside the cell:

- `network: none`: the only interface is `lo`.
- `read-only`: the root filesystem is mounted `ro`.
- The tmpfs `noexec` flag.
- `cap-drop`: the bounding capability set is empty.
- `no-new-privileges`.
- The uid.

A flag that the cell can't read fails the check rather than passing it.

Conformance doesn't observe the tmpfs `nosuid` and `nodev` flags, `pids-limit`, or the resource limits.
You must get those right yourself. To check them, see [Verify an accessory](container.md#verify-an-accessory).

### The application's group membership

Conformance checks the shared group from the cell's side, because it runs the cell as `10001` against
files that a different user owns: `health.reopen` proves that a cell can open an input by name, and
`example.tamper` proves that it can do nothing else with either file.

It can't check the application's side. Its driver owns the files as root, which needs no group membership
to set a group. A missing membership fails as `EPERM` in the application rather than in the cell. See
[The shared group](client-api.md#the-shared-group).
