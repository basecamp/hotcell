---
type: Design
title: "Passing file descriptors"
order: 4
description: "The argument for passing file descriptors instead of sharing a directory, and what it costs."
---

# Passing file descriptors

The obvious alternative is a directory mounted into both containers: the app writes an input file and
names it, the cell writes an output file and names it. It is simpler, and it has one real advantage this
design gives up.

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
and it is a window, not a wall. See [Worker isolation](worker-isolation.md).

**Nothing is left at rest.** A volume is persistent and outlives requests, so it holds user content
somewhere neither side owns, and a crashed worker leaves it there. The socket directory holds a socket and
no data.

**Descriptors protect naming, and only naming.** The bytes are copied to the cell's tmpfs when
an operation asks for a path, so the cell has full read and write on its own copy. The output is a file
the app created and the cell writes arbitrary bytes into it either way, so a compromised cell can return a
malicious image and the app will publish it. Validating content is the application's job.

**The cost, accepted knowingly.** A bind mount crosses Docker Desktop's VM boundary and a descriptor does
not, so a volume-based design would let macOS developers run the real container with the real hardening.
Descriptors cost us that, which is why development runs a cell uncontainerized on every platform. Removing
a whole class of naming bug is worth more than development parity, because that class fails silently and
each mitigation for it has to be remembered forever.

**Where a volume wins, and it is not a corner case.** An input larger than the cell's tmpfs cannot be
posted in at all. Video shows it plainly: a 3GB blob will not spool onto a 512MB tmpfs at any body limit,
and `ffprobe` reads only a container header, so store-and-forward costs roughly 300× I/O amplification on
its commonest call. The descriptor itself already refers to a file on the application's own filesystem;
the amplification comes from the **copy** an input performs when asked for its path. So the fix is per-operation and stays inside this design: an operation
that can consume a descriptor directly never asks, and never pays.
