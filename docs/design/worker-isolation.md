---
type: Design
title: "Worker isolation"
order: 3
description: "What one worker can and cannot reach of another, and the residuals that remain."
---

# Worker isolation

Workers in a cell are siblings under one UID in one PID namespace, so another worker's `/proc` entries are
same-UID reads. Measured, not assumed — items 7 and 8 of [Established by experiment](../contributing/experiments.md):

| Target | At `ptrace_scope = 1` | Why |
| --- | --- | --- |
| `/proc/<sibling>/mem` | `EACCES` | Needs `PTRACE_MODE_ATTACH`, which Yama restricts to descendants. |
| `/proc/<sibling>/environ` | **Readable** | Needs only `PTRACE_MODE_READ`, which Yama does not restrict. |
| `/proc/<sibling>/fd/N` | **Readable** | Same `PTRACE_MODE_READ`. So are the scratch files themselves, by directory listing. |

So invariant 8 has three parts and they have different answers. Only the first is about `ptrace_scope`.

**Request memory** is protected by `kernel.yama.ptrace_scope >= 1`. That is a host sysctl a container
cannot set, so it is a deployment precondition. At `ptrace_scope = 0` the guarantee is gone, and the cell
therefore **refuses to boot** rather than logging a warning and serving anyway. A host sysctl is invisible
to the image, it silently voids the guarantee, and a warning in a log is how a dead control stays dead.

**Above `max_requests_per_worker: 1` this invariant is about workers, not requests.** A worker serving
several requests in turn holds each of them in the same address space, so an input that achieves code
execution can read and tamper with every later request that worker handles — no race to win, and covering
requests that were never concurrent with it. That is a deliberate setting with a measured payoff; see
[ADR 0001](../../adr/0001-reuse-workers-across-requests.md). It is the only place in this design where the
isolation between two requests is a configuration value.

**Nothing on disk carries from one request to the next.** A slot holds one directory per request, which is
that request's `$HOME` and also where its inputs and outputs are staged, and it is created when the request
starts and removed before the caller hears the answer. A home that outlived its request would carry
configuration to the next one, and for these toolchains configuration is executable: ImageMagick runs the
command lines in `delegates.xml` and applies the rights in `policy.xml`, both read from
`$HOME/.config/ImageMagick`. One input that achieved code execution could then reconfigure every later
request on that slot, which is the bound `max_requests_per_worker: 1` exists to hold.
[ADR 0003](../../adr/0003-remove-the-persistent-slot-home.md) records the decision.

The directory carries a fresh unpredictable name for every request, and that is what makes the removal a
guarantee rather than an intention. A tool that reaches code execution runs as the user that owns the tree,
so it can `chmod 0500` its own configuration directory and the slot directory around it, and both the
worker's delete and the supervisor's rename then fail. A fresh name means the next request never receives
a tree that an earlier request prepared. A mode is also not a permission the process lost, so a cleanup
that fails on one is retried after putting the mode back, and what a cleanup that still fails costs is disk
rather than isolation.

**That bounds what a finished request left behind, and not what a live process is doing.** Every worker runs
as the same uid, and `0700` is that uid's own mode, so a concurrent sibling can write into a home as soon as
it exists — and so can a `setsid` descendant of a request that has already answered, which process groups do
not contain. The slot directory itself is a name a worker can rename aside and replace, and a pathname
`chmod` follows what it finds. Those are the residuals below, and a fresh name does not close them: it
closes the offline route, where nothing of the attacker's is still running.

**Files are not isolated between concurrent workers, and cannot be.** Every worker runs as the same uid in
one mount namespace, so a worker that reads another worker's scratch directory — by listing it, or through
`/proc/<sibling>/fd/N` — gets that request's input and output bytes. Unlinking the scratch file does not
close it, because the descriptor is still reachable through the sibling's `/proc`. The two fixes that
would work need `CAP_SETUID` for a per-worker uid or `CAP_SYS_ADMIN` for a per-request mount namespace,
and `cap-drop ALL` removes both. This is the same shape as the environment: a real residual, stated rather
than papered over.

What bounds it is the size of the window and the value of the contents. Only requests actually in flight
have bytes inside a cell, a cell holds no credentials, and a cell carries one toolchain. So the exposure
is "the other conversions happening right now in this cell", which is why per-toolchain cells and a sober
`concurrency` are containment decisions and not just scheduling ones.

**A compromised worker can steal the cell's sockets.** It unlinks `work.sock` and binds its own, and every
later request arrives at its listener with the caller's descriptors already attached. It may then read
those inputs, write those outputs, and answer `ok`. This works because the socket directory has to be
writable by the user the supervisor runs as, and workers run as that user.

The worker that did it exits as designed and its listener does not, because a child it forked calls
`setsid` and leaves the process group the reap sweep kills. So the reach is every request the cell
serves from then on, rather than only the ones in flight: the bound above covers one worker reading
another's files, and it does not cover this.

**Nothing stops this today.** Every prevention available needs something the deployment does not have. A
tighter directory mode is undone by the owner, and the sticky bit grants the owner what it withholds from
others. The immutable flag needs `CAP_LINUX_IMMUTABLE` and a uid per worker needs `CAP_SETUID`, and
`cap-drop ALL` removes both. An abstract-namespace socket has no name to unlink and cannot be reached
across `network: none`.

[Landlock](https://github.com/basecamp/hotcell/issues/13) is the one prevention that fits an unprivileged
container: a worker gives up write access to the socket directory right after the fork, irreversibly and
with no capability. Until then this is a known gap, and the containment is the same as for a compromise
generally — a cell holds no credentials, carries one toolchain, and is replaced rather than repaired.

Fork-per-request isolates each request's **memory**. The argument in
[Passing file descriptors](descriptors.md) is about the boundary between the application
and the cell, and it doesn't extend to workers inside one cell.

**Environment** is not protected by `ptrace_scope` at all, and cannot be fixed inside the worker. A forked
process's `/proc/self/environ` is the exec-time environment of the process it was forked from, so a worker
calling `ENV.delete` changes nothing about what a sibling reads. Two controls replace it. Invariant 2
keeps anything worth stealing out of a cell's environment in the first place. And invariant 9 requires
tools to be spawned with `unsetenv_others: true` and an explicitly written environment, because a tool is
`exec`ed and therefore does get a fresh `/proc/<pid>/environ` — the one thing in this picture that is
actually under our control.

`hidepid=2` on `/proc` would hide sibling processes entirely and remove the sysctl dependency. Docker
can't provide it: it rejects Podman's `--security-opt proc-opts=`, and remounting `/proc` inside the
container needs `CAP_SYS_ADMIN`, which `cap-drop ALL` removes.
