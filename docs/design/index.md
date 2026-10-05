---
title: "Design"
description: "The threat model, the invariants, worker isolation, and why descriptors: what the code cannot tell you."
---

# Design

These pages hold the parts of HotCell's design that reading the code can't give you: why the work moves
out of the application process at all, what a cell is defended against, and the invariants that the whole
design exists to hold.

The gems' APIs and behavior are in the reference pages in [`docs/`](../index.md). Each of those lists
the code that it describes in its `sources`, so that a change to that code flags the page. See
[Keep the docs current](../development/docs.md).

<!-- index -->

| Page | Description |
| --- | --- |
| [Why descriptors rather than a shared volume](descriptors.md) | The argument for passing file descriptors instead of sharing a directory, and what it costs. |
| [Invariants](invariants.md) | The numbered properties the design exists to hold. Code and tests cite them by number. |
| [Threat model](threat-model.md) | What HotCell is, the problem it solves, and what a cell is defended against. |
| [Worker isolation](worker-isolation.md) | What one worker can and cannot reach of another, and the residuals that remain. |

<!-- indexstop -->

The facts that were measured rather than reasoned about, and the decision records, are in
[Developing HotCell](../development/index.md).
