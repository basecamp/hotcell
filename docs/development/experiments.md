---
type: Design
title: "Established by experiment"
description: "The numbered facts that were measured rather than reasoned about. Code and docs cite them by number."
---

# Established by experiment

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
