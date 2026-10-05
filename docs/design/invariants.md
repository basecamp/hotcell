---
type: Design
title: "Invariants"
description: "The numbered properties the design exists to hold. Code and tests cite them by number."
---

# Invariants

These are the properties the design exists to hold. Code and tests across three gems cite them by number,
so the numbers never change. Number 1 is retired.

2. A cell holds no application credentials, in its environment or on its filesystem.
3. The supervisor never evaluates image data, and a worker forked from it produces correct output.
4. Descriptor access modes are one-way: an input can't be written, and an output can't be read.
5. The cold side never opens a filesystem path that a hot side chose.
6. An operation can't exceed its cell's limits, whatever it declares.
7. A cell can't reach another cell's socket.
8. A worker can't read another request's memory, given `kernel.yama.ptrace_scope >= 1` on the host and
   `max_requests_per_worker: 1`. [Worker isolation](worker-isolation.md) covers files and the environment.
9. A tool subprocess sees only the environment that its operation wrote for it.

Tests cover the invariants where reading the code isn't enough: where the kernel enforces the property,
where a break would be silent, or where a plausible refactor would remove it.

Invariant 2 is a property of a whole filesystem, so no single test asserts it. The tests check that the
built image contains no application source tree, and `bin/conformance` boots the hardened container and
checks its flags.
