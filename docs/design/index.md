---
title: "Design"
description: "The threat model, the invariants, worker isolation, and the facts established by experiment: what the code cannot tell you."
---

# Design

These pages hold the parts of HotCell's design that reading the code can't give you: why the work moves
out of the application process at all, what a cell is defended against, the invariants that the whole
design exists to hold, and the facts that were measured rather than reasoned about.

They don't describe the gems' APIs or behavior. An earlier version of this document did, and it went
stale as soon as the code moved; worse, its errors spread back into the code's own comments. The
reference pages in [`docs/`](../index.md) describe behavior now, and each one lists the code that it
describes in its `sources`, so that a change to that code flags the page. See
[AGENTS.md](../../AGENTS.md#keep-the-docs-current).

<!-- index -->

| Page | Description |
| --- | --- |
| [Why descriptors rather than a shared volume](descriptors.md) | The argument for passing file descriptors instead of sharing a directory, and what it costs. |
| [Established by experiment](experiments.md) | The numbered facts that were measured rather than reasoned about. Code and docs cite them by number. |
| [Invariants](invariants.md) | The numbered properties the design exists to hold. Code and tests cite them by number. |
| [What the overhead measures at](overhead.md) | Where the fixed cost of a call comes from, and the candidates that were ruled out. |
| [Threat model](threat-model.md) | What HotCell is, the problem it solves, and what a cell is defended against. |
| [Worker isolation](worker-isolation.md) | What one worker can and cannot reach of another, and the residuals that remain. |

<!-- indexstop -->

Decisions that were argued rather than obvious are in [`adr/`](../../adr/README.md).
