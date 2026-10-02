# Conformance

### Bringing your own container

If you prefer to use your own base image to run HotCell, that's fine!

#### Conformance checks

`bin/conformance IMAGE` checks whether an image supports hotcell. It boots the image with the flags
under "Container settings", mounts the example operations over `/hotcell/operations`, and drives a
battery of checks from a second container over a shared volume: descriptor round-trips, each kill
verdict, refusal at capacity, and the isolation flags. It exits non-zero on the first failed check.

It then runs the same battery again against your image booted without one security flag at a time, and
requires each run to fail at that flag's own check. That is what makes the isolation results a test of
the flags rather than a restatement of them: a check that cannot see a flag would pass a cell running
without it. A runtime that force-mounts `noexec` onto every tmpfs — Docker Desktop does — cannot host
the `noexec` negative, and that one run reports `SKIP` with the reason.

```
docker build -t my-cell:test hotcell/
bin/conformance my-cell:test
```

The mount shadows the operations your image carries. What the checks cover is the image's runtime — its
Ruby, its gems, and its socket behaviour — not the work your operations do.

`bin/example-image` builds an image to try it against. CI runs both on every push.

#### Additional requirements

Three things conformance cannot prove for you.

**`kernel.yama.ptrace_scope >= 1` on the host.** No container flag can supply it, and it is what stops one
worker reading another request's memory through `/proc/<pid>/mem`. A cell refuses to boot below it:

```
kernel.yama.ptrace_scope is 0 on this host, so one worker can read another request's memory
through /proc/<pid>/mem. No container flag can set it. Set it to 1 or higher and boot again.
```

A host that does not expose the file at all logs `cell.ptrace_scope_unknown` and boots anyway.

**The security flags it cannot observe.** It reads six from inside the cell: `network: none` (the only
interface is `lo`), `read-only` (the root filesystem is mounted `ro`), the tmpfs `noexec` flag, `cap-drop`
(the bounding capability set is empty), `no-new-privileges`, and the uid. A flag the cell cannot read fails
the check rather than passing it. It does not observe the tmpfs `nosuid` and `nodev` flags, `pids-limit`,
or the resource limits. Those are yours to get right, and "Verifying your accessory" is how.

**Your application's group membership.** Conformance does check the shared group, because it runs the cell
as `10001` against files a different user owns: `health.reopen` proves a cell can open an input by name,
and `example.tamper` proves it can do nothing else with either file. What it cannot reach is the
application's own side — its driver owns the files as root, which needs no membership to set a group. That
one fails as `EPERM` in the application rather than in the cell.
