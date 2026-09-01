# HotCell — design

The code is the specification. This document holds the parts of the design that reading the code cannot
give you: why the work moves out of the application process at all, what a cell is defended against, the
invariants the whole thing exists to hold, and the facts that were measured rather than reasoned about.

It deliberately does not describe the gems' APIs. That description used to live here, it went stale as
soon as the code moved, and worse, its errors propagated back into the code's own comments. Behavior
belongs in the code and its tests; [CONTRIBUTING.md](../CONTRIBUTING.md) covers working on them, and
[docs/DEPLOYMENT.md](DEPLOYMENT.md) covers running one.

## What this is

HotCell moves untrusted work out of a privileged application process into an unprivileged,
resource-capped, network-less sibling container. The application reaches in through a narrow interface.
The work never reaches out.

A hot cell is a shielded chamber for handling highly radioactive material. The operator stays outside and
manipulates the contents remotely, and nothing leaves except by controlled transfer. The vocabulary
follows: **hot** is untrusted, **cold** is trusted, and material is **posted in** and **posted out**.
Everything else uses the ordinary word.

## The problem

Firejail and similar sandboxes do not work inside a container, because containers and sandboxing use the
same kernel features. An application deployed in a container therefore runs media libraries unconfined. A
vulnerability in libvips, `soffice`, `mutool`, `ffmpeg`, or ImageMagick, reached through an uploaded file,
executes with the application's secrets, its database credentials, its code, and its network.

Two properties of `/proc` shape the response. Scrubbing a tool's environment does not help, because a
file-read primitive can retarget `/proc/<parent>/environ` at a same-UID process and read the environment
that the scrubbed invocation was supposed to hide. And moving secrets out of the environment does not help
either, because the same primitive reads arbitrary files, including a credentials file such as
`config/master.key`.

That leaves two remedies: a bubblewrap or nsjail wrapper inside the application image, or a separate
conversion service holding no secrets. HotCell is the second. The second also avoids an open question the
first carries, which is whether an in-image wrapper survives the container runtime it is deployed under.
That is the verification firejail does not pass.

## Threat model

Assume arbitrary code execution inside a cell, or merely an arbitrary file read, reached through a
malicious input file. The design must make that outcome cheap.

In scope: reading application code or secrets, reaching the database, reaching the network, reading
another request's memory or environment, consuming the host's CPU or disk, escalating through a path the
application later opens, and reaching a different cell's toolchain.

Out of scope: a kernel container escape, a malicious operation implementation, and denial of service
against a cell.

Out of scope means the design does not promise to stop it, not that it is harmless. A malicious operation
— most plausibly a supply-chain compromise in a gem an operation depends on — is in fact contained by
everything here, because an operation runs in the same cell under the same limits as the library it
calls. It is excluded because it is not what this design is *for*, and because treating it as in scope
would drag operation review and dependency policy into a document about a transport.

The minimum requirement is a PID and mount namespace exposing only the input and output, with no `/proc`
and no application filesystem. HotCell meets the namespace requirement by being a separate container, and
**exceeds the input/output part**: descriptors mean there is no path in the cell to expose or to traverse,
rather than a narrowed set of bind mounts. The `/proc` requirement is treated separately under "Worker
isolation", because it is the one part a container boundary does not give us for free.

## The invariants

These are the design properties the whole thing exists to hold. They are not a test plan. Most are
verifiable by reading the code, and a test that restates what an obvious ten-line method plainly does buys
nothing but maintenance. Test the ones where inspection is not enough — where the behaviour is the
kernel's rather than ours, where it is silent when broken, or where a plausible refactor would quietly
remove it.

**These numbers are load-bearing.** Code and tests across three gems cite them by number. Do not renumber
them, and mark one withdrawn rather than removing it.

1. ~~No application framework loads in a cell.~~ **Withdrawn.** Nothing enforces this and nothing should.
   The whole design is that the container provides the guarantee structurally, so policing what code runs
   inside it both duplicates a control that already holds and implies it does not. Under `network: none` a
   loaded `ActiveRecord` cannot reach a database, and untouched pages are not copied, so the
   copy-on-write argument for warning about it was not real either. Keeping a cell's gem graph small is
   still worth doing — a smaller graph is a smaller thing to audit — but that is a budget, not a rule
   about what an operation may require.
2. A cell holds no application credentials, in its environment **or on its filesystem**.
3. The supervisor never evaluates image data, and a worker forked from it produces correct output.
4. Descriptor access modes are one-way: an input cannot be written, an output cannot be read.
5. No filesystem path chosen by a hot side is ever opened by the cold side.
6. An operation cannot exceed its cell's limits, whatever it declares.
7. A cell cannot reach another cell's socket.
8. A worker cannot read another **request's** memory. Conditional on two things:
   `kernel.yama.ptrace_scope >= 1`, a host setting no container flag can supply, and
   `max_requests_per_worker: 1`. Not files — see "Worker isolation".
9. A tool subprocess sees only the environment its operation wrote for it.

Invariant 2 is the awkward one. "A cell holds no application credentials" is a negative over a whole
filesystem and cannot be asserted directly. It stays on the list anyway, because it is the property the
whole design exists to hold. What the tests can reach is narrower: the built image contains no application
source tree, and `bin/conformance` boots the hardened container and checks its flags directly.

A cell could go further and enforce it, by reading an allowlist of environment variable names and refusing
to boot on anything outside it. That is deferred, not rejected. It is a boot check that can be added at
any time without touching anything else here, and it addresses an operator mistake rather than the threat
this design is about.

## Worker isolation

Workers in a cell are siblings under one UID in one PID namespace, so another worker's `/proc` entries are
same-UID reads. Measured, not assumed — items 7 and 8 below:

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
[ADR 0001](../adr/0001-reuse-workers-across-requests.md). It is the only place in this design where the
isolation between two requests is a configuration value.

**Nothing on disk carries from one request to the next.** A slot holds one directory per request, which is
that request's `$HOME` and also where its inputs and outputs are staged, and it is created when the request
starts and removed before the caller hears the answer. It used to survive across worker processes, to keep
an expensive per-user profile warm. That was a hole rather than a trade: what a tool reads from `$HOME` is
configuration, and for these toolchains configuration is executable — ImageMagick runs the command lines in
`delegates.xml` and applies the rights in `policy.xml`, both read from `$HOME/.config/ImageMagick`. So one
input that achieved code execution could reconfigure every later request on that slot, which is precisely
the bound `max_requests_per_worker: 1` exists to hold. [ADR 0003](../adr/0003-remove-the-persistent-slot-home.md)
records the reversal.

The directory carries a fresh unpredictable name for every request, and that is what makes the removal a
guarantee rather than an intention. A tool that reaches code execution runs as the user that owns the tree,
so it can `chmod 0500` its own configuration directory and the slot directory around it, and both the
worker's delete and the supervisor's rename then fail. Under a stable name the next request was handed the
tree that had just refused to go. A name no earlier request has held is not a name an earlier request could
have prepared. A mode is also not a permission the process lost, so a cleanup that fails on one is retried
after putting the mode back, and what a cleanup that still fails costs is disk rather than isolation.

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

Detection was tried and withdrawn. The supervisor can record each socket's inode and re-check it, and an
attacker defeats that by hard-linking the original aside, serving from an impostor, and renaming the
original back before the next check: the inode then matches and the theft leaves no trace. Measured. The
check also cost more than it bought, because a supervisor that stops on a changed inode will unlink its
successor's sockets during an overlapping restart.

[Landlock](https://github.com/basecamp/hotcell/issues/13) is the one prevention that fits an unprivileged
container: a worker gives up write access to the socket directory right after the fork, irreversibly and
with no capability. Until then this is a known gap, and the containment is the same as for a compromise
generally — a cell holds no credentials, carries one toolchain, and is replaced rather than repaired.

This corrects an overclaim worth being explicit about, because it is easy to make: fork-per-request buys
**memory** isolation, not file isolation. The argument for descriptors below is about the boundary between
the application and the cell, and it does not extend to workers inside one cell.

**Environment** is not protected by `ptrace_scope` at all, and cannot be fixed inside the worker. A forked
process's `/proc/self/environ` is the exec-time environment of the process it was forked from, so a worker
calling `ENV.delete` changes nothing about what a sibling reads. Two controls replace it. Invariant 2
keeps anything worth stealing out of a cell's environment in the first place. And invariant 9 requires
tools to be spawned with `unsetenv_others: true` and an explicitly written environment, because a tool is
`exec`ed and therefore does get a fresh `/proc/<pid>/environ` — the one thing in this picture that is
actually under our control.

`hidepid=2` on `/proc` would remove the sysctl dependency by hiding sibling processes entirely, and it is
not available: Docker rejects Podman's `--security-opt proc-opts=`, and remounting `/proc` inside the
container needs `CAP_SYS_ADMIN`, which `cap-drop ALL` removes. Revisit only if the runtime changes.

This is the third `/proc` surprise in this design, after `/proc/self/fd/N` laundering a read-only
descriptor and the environ retargeting that motivated the whole project. `/proc` is where these
assumptions go to die, and it deserves the attention.

## Established by experiment

Each of these was measured, not reasoned about. A specification cannot derive them, getting them wrong
produces failures that are hard to diagnose, and several constrain the architecture rather than the
implementation.

1. **libvips cannot survive `fork` once it has evaluated an image.** After `require` and
   `Vips.concurrency_set` the process has three threads and forks children that work; the first image
   evaluation takes it to five, and from then on **every** forked child deadlocks in `futex_do_wait`,
   permanently. Reproducible. This is the whole reason for the `before_fork` and `before_worker_boot`
   split, and the reason `before_fork` may require and configure but must never evaluate.
2. **Two descriptors over `SCM_RIGHTS` work end to end**, with `Vips::Source.new_from_descriptor` and
   `Vips::Target.new_to_descriptor`, and the kernel enforces the access modes: writing an input or reading
   an output raises `Errno::EBADF`.
3. **Reopening `/proc/self/fd/N` defeats a read-only descriptor**, because it is a fresh `open` rechecked
   against the inode and does not inherit the original flags. Never use it to turn a descriptor into a
   filename. Copy instead.
4. **An empty Docker named volume takes its ownership from the image of whichever container mounts it**,
   even if an earlier container already mounted it, provided it is still empty. So accessory and app boot
   order does not matter. A bind mount instead takes the host directory's ownership, which is why local
   development needs the directory created first.
5. **Kamal 2.11 hard-codes `--network kamal` for app roles.** Only accessories accept `network`, and only
   as an accessory key. Under `options:` it is additive rather than overriding — Kamal emits its own
   `--network` first — and Docker then refuses the container. Accessories can target `roles: [web, jobs]`,
   and are not updated by a deploy.
6. **A worker killed by a resource limit produces a bare end of stream**, which is why the supervisor must
   hold the connection and report `killed`. A `memory` breach does this too, roughly a third of the time:
   libvips 8.18 dereferences null on its own out-of-memory path and takes `SIGSEGV` at
   `vips_image_decode` *after* printing the correct diagnostic, and GLib's non-nullable `g_malloc` aborts.
   So the reap-and-report path carries `memory` as well as `fsize`.
7. **A sibling process's `/proc/<pid>/mem` is `EACCES` at `ptrace_scope = 1`, but its
   `/proc/<pid>/environ` is readable.** Verified with two same-UID siblings forked from one parent: the
   environ read returned the victim's canary. Yama restricts `PTRACE_MODE_ATTACH`, which `mem` needs, and
   does not restrict `PTRACE_MODE_READ`, which `environ` needs.
8. **A forked process cannot change what its own `/proc/self/environ` shows.** That view is the exec-time
   environment, so `ENV.delete` in a worker is invisible to a reader. Only an `exec`ed child gets a fresh
   one, which is why `unsetenv_others` on the tool spawn is the control.
9. **Docker cannot mount `/proc` with `hidepid`.** `--security-opt proc-opts=hidepid=2` is a Podman
   feature; Docker rejects it outright, and remounting inside the container needs `CAP_SYS_ADMIN`.
10. **LibreOffice corrupts itself when two instances share a `$HOME` profile.** That is the origin of
    slots. A hardened conversion measures at roughly 613ms, which sizes a soffice cell's deadline
    concretely.
11. **`RLIMIT_AS` is unusable and `RLIMIT_DATA` is expensive.** For a real variant whose peak RSS is 45MB,
    `RLIMIT_AS` must be at least 1536MB to succeed reliably and fails nondeterministically for a 400MB
    band below that; `RLIMIT_DATA` works at 704MB. `RLIMIT_DATA` charges private writable anonymous
    mappings and ignores `PROT_NONE` reservations, read-only private file mappings, and `MAP_SHARED`
    entirely. It does charge thread stacks, so shrinking `RLIMIT_STACK` at container entry is worth real
    headroom — and `RLIMIT_STACK` cannot be changed after `exec`, because glibc snapshots it at init.
12. **Ruby reserves about 450MB of `RLIMIT_DATA` at boot and never touches it.** A single ~404MB writable
    anonymous region, introduced in 3.3 and unchanged in 3.4 and 4.0, unaffected by the GC and malloc
    environment knobs. It is why the `memory` floor is what it is, and why `memory` cannot be read as how
    much a bomb may consume.
13. **A cgroup memory kill is a prompt, silent `SIGKILL` with no diagnostic**, and the kernel chose the
    allocating worker rather than the supervisor in every trial, because badness is RSS-proportional. The
    argument for a per-worker limit is the diagnostic, not the choice of victim.
14. **Plain `require "vips"` leaves the libheif plugins un-`dlopen`ed.** They then load lazily inside the
    worker, after its limits are on, where `dlopen` fails with only a warning and the process continues
    with HEIC and AVIF missing — turning a limit breach into `unreadable` for a whole format family.
    `require "image_processing/vips"` or `Vips.block_untrusted true` maps them in the supervisor instead.
15. **`fork` costs about 2.8ms**, measured as `fork` + `exit!` + `wait` from a 58MB three-thread parent
    with libvips required and never evaluated. It is a small part of the cell's fixed overhead, not most
    of it.
16. **The cell's fixed overhead is copy-on-write settling, and it is proportional to the supervisor's
    resident heap.** A worker's first pipeline run takes about 7,900 minor faults against 1,564 for a warm
    process. Forking the same work from a 265MB parent instead of a 58MB one took faults to about 25,900
    and added roughly 52ms per request. So preloading generously in the supervisor makes every request
    slower for the life of the deployment. `RLIMIT_AS` and libvips thread-pool size were both tested and
    neither moves it.
17. **macOS has no finite `RLIMIT_DATA`.** `Process.setrlimit` rejects one with `EINVAL`, and the
    inherited hard limit is already infinity, so it is not a privilege problem. A cell there runs with its
    memory clamp unenforced and warns once. Every other limit is strict on both platforms.
18. **Re-opening `/dev/fd/N` is checked against the opening process's credentials and the file's mode.**
    Not against the caller's. So a cell handed a descriptor for a mode `0600` file the application owns
    cannot open it by name at all, and every operation that gives a tool a filename dies as `EACCES`.
    Operations that read the descriptor directly are unaffected, which is why the failure looks selective.
    The mode is also what enforces invariant 4 once a tool holds a filename: at `0400` even the owner is
    refused `O_RDWR`, and at `0200` even the owner is refused a read. That holds only while the cell does
    not own the file. Changing a mode needs ownership, and `cap-drop ALL` leaves no capability that
    overrides it — so a shared group enforces the invariant and a shared uid cannot.

19. **On darwin, `open("/dev/fd/N")` is a `dup` of fd N rather than a reopen of the file behind it.**
    Linux's `/dev/fd` is `/proc/self/fd`, where the open is real and starts at offset zero; darwin's is
    the `fdesc` filesystem, and its open shares the caller's file offset. A tool is free to open the path
    it is handed more than once — libvips sniffs a format by opening it once per candidate loader and
    reading the first few bytes — and on a shared offset each of those reads starts where the last one
    stopped. A HEIC file, whose loader is late in libvips' priority order, is never recognised and comes
    back `unreadable` with no error anywhere. Reopening the caller's own file is not available as a
    remedy: its path is the cold side's, and no path the cold side chose is ever visible to a tool. So
    `Input#fd_path` stages on
    darwin, and an uncontainerized macOS cell pays for a copy and the `RLIMIT_FSIZE` ceiling that bounds
    it. Production is Linux and pays neither.

## Why descriptors rather than a shared volume

The obvious alternative is a directory mounted into both containers: the app writes an input file and
names it, the cell writes an output file and names it. It is simpler, and it has one real advantage this
design gives up. Recorded here because the reasoning is not obvious and will otherwise be relitigated.

**It removes a class of bug rather than a bug, and that is the deciding reason.** With a volume the app
must open a path the cell can write to. The cell creates that path as a symlink to
`/rails/config/master.key`, which resolves in the *app's* mount namespace; the app reads it and publishes
it as a public image variant. `O_NOFOLLOW` closes that, but only for the final component, so an
intermediate directory symlink still works, and closing that needs `openat2` with `RESOLVE_NO_SYMLINKS`,
which Ruby does not expose. Add a sticky exchange directory so the cell cannot unlink the app's files,
have the app pre-create both files, validate the descriptor with `fstat` for a regular file and an exact
size, and never list the directory. That is a checklist that must each be remembered forever, each item
failing silently. Descriptors have no such checklist, because there is no path.

The checklist is not hypothetical. A volume-based service arrives at it item by item: a token validated
against `\A[a-f0-9]{32}\z`, a path built server-side from one component,
`O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, an `fstat` on the descriptor for a regular file and an exact size under
a maximum, and then **the open descriptor rather than the path handed to the tool.** Which is to say it
arrives at descriptor passing anyway, having paid for the volume first.

**Cross-request isolation is a smaller reason than it first appears.** Under a shared volume every worker
can read every request's bytes in the directory, including requests not currently running. Under
descriptors only in-flight requests have bytes inside the cell. That narrower window is the real gain —
and it is a window, not a wall. See "Worker isolation".

**Nothing is left at rest.** A volume is persistent and outlives requests, so it holds user content
somewhere neither side owns, and a crashed worker leaves it there. The socket directory holds a socket and
no data.

**What descriptors do not buy, so nobody oversells them.** The bytes are copied to the cell's tmpfs when
an operation asks for a path, so the cell has full read and write on its own copy. The output is a file
the app created and the cell writes arbitrary bytes into it either way, so a compromised cell can return a
malicious image and the app will publish it. Descriptors protect *naming*. They do not protect or validate
content.

**The cost, accepted knowingly.** A bind mount crosses Docker Desktop's VM boundary and a descriptor does
not, so a volume-based design would let macOS developers run the real container with the real hardening.
Descriptors cost us that, which is why development runs a cell uncontainerized on every platform. Removing
a whole class of naming bug is worth more than development parity, because that class fails silently and
each mitigation for it has to be remembered forever.

**Where a volume wins, and it is not a corner case.** An input larger than the cell's tmpfs cannot be
posted in at all. Video shows it plainly: a 3GB blob will not spool onto a 512MB tmpfs at any body limit,
and `ffprobe` reads only a container header, so store-and-forward costs roughly 300× I/O amplification on
its commonest call. Note carefully what this is *not* an argument against — descriptor passing has no
such problem, because the descriptor already refers to a file on the application's own filesystem. The amplification comes from the **copy** an input performs when asked for
its path, not from the transport. So the fix is per-operation and stays inside this design: an operation
that can consume a descriptor directly never asks, and never pays.

## What the overhead measures at

Read this section for its negative results rather than its numbers. The numbers came off a laptop from a
prototype; the things that were ruled out are properties of the design. For the reuse trade specifically,
[ADR 0001](../adr/0001-reuse-workers-across-requests.md) supersedes this with measurements taken in the
deployed artifact.

Three arms, each producing a 256×256 PNG with `resize_to_fill`: in process, a native cell over a Unix
socket, and a containerized cell with the hardening flags on. The cell arms ran 2.3×, 1.9×, and 1.7×
slower as the source grew from a 12KB JPEG to a 328KB one.

**The overhead is roughly fixed at 25 to 35 ms**, which is why the multiplier falls as the work grows.
Expect the ratio to look worst on the smallest thumbnails and to stop mattering on anything expensive.

Four candidates were tested and eliminated, recorded so nobody re-runs them:

| Candidate | Verdict |
| --- | --- |
| The container | Within noise of the native cell on two of three sources, 12ms on the largest. |
| The `fork` syscall | 2.8 ms of a 20–30 ms cost. |
| `RLIMIT_AS`, which the worker sets and the in-process arm does not | No effect. 8 GB, 2 GB, and unset are indistinguishable. |
| libvips thread pool startup per worker | Not it. The first-versus-second-call gap is *largest* at concurrency 1. |
| The libvips operation cache, as a confound favouring the in-process arm | Not it. `Vips.cache_set_max 0` moved that column by less than the error bars. |

**The overhead is copy-on-write, measured rather than inferred.** The identical pipeline runs about 14 ms
slower in a freshly forked worker than in a long-lived process. Run it *twice* in the same child and the
second call matches a warm process, so it is one cost per process, not per call. Minor fault counts say
what it is: **7,920 faults on a child's first call against 1,564 warm**, about 25 MB of pages copied at
roughly 1.7 µs each.

**So the cheapest optimisation is the counter-intuitive one: keep the supervisor small, and treat
`before_fork` as having a per-request price.** The instinct is to preload generously so workers start
fast. It is backwards here — every megabyte the supervisor holds is partly copied by every worker for the
rest of the deployment. `before_fork` must still `require`, because of the fork hazard in item 1 above, so
the resolution is to require only what that cell's own operations need. That is a third argument for one
cell per toolchain, and a measured reason for `hotcell-server` not to depend on `activesupport`.

Do not spend effort making the container cheaper. There is nothing there to win.

**Synthetic pre-warming is not a free alternative to worker reuse.** Tested, because it would have been
the ideal answer: running a synthetic 64×64 pipeline in the worker before the real transform moved the
real transform's faults from 7,885 only to 6,184, against a warm floor of about 3,300 — roughly a quarter
of the excess. Most of the cost is proportional to the real image's own work, not to shared code paths a
synthetic image would touch.

Budget the fixed cost against inline processing. A variant generated during an upload request, as Active
Storage's `process: :immediately` does, adds this overhead to that request. Whether that is acceptable is
a product decision, and it is the main reason to measure it early on real hardware.
