---
type: Design
title: "Invariants"
description: "The numbered properties the design exists to hold. Code and tests cite them by number."
---

# Invariants

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
   `max_requests_per_worker: 1`. Not files — see [Worker isolation](worker-isolation.md).
9. A tool subprocess sees only the environment its operation wrote for it.

Invariant 2 is the awkward one. "A cell holds no application credentials" is a negative over a whole
filesystem and cannot be asserted directly. It stays on the list anyway, because it is the property the
whole design exists to hold. What the tests can reach is narrower: the built image contains no application
source tree, and `bin/conformance` boots the hardened container and checks its flags directly.

A cell could go further and enforce it, by reading an allowlist of environment variable names and refusing
to boot on anything outside it. That is deferred, not rejected. It is a boot check that can be added at
any time without touching anything else here, and it addresses an operator mistake rather than the threat
this design is about.
