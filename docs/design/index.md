# Design

These pages hold the parts of HotCell's design that reading the code can't give you: why the work moves
out of the application process at all, what a cell is defended against, the invariants that the whole
design exists to hold, and the facts that were measured rather than reasoned about.

They don't describe the gems' APIs or behavior. An earlier version of this document did, and it went
stale as soon as the code moved; worse, its errors spread back into the code's own comments. The
reference pages in [`docs/`](../index.md) describe behavior now, and each one lists the code that it
describes in its `sources`, so that a change to that code flags the page. See
[AGENTS.md](../../AGENTS.md#keep-the-docs-current).

| Page | Description |
| --- | --- |
| [Threat model](threat-model.md) | What HotCell is, the problem it solves, and what is in and out of scope. |
| [Invariants](invariants.md) | The numbered properties that the design exists to hold. Code and tests cite them by number. |
| [Worker isolation](worker-isolation.md) | What one worker can and can't reach of another, and the residuals that remain. |
| [Established by experiment](experiments.md) | The numbered facts that were measured rather than reasoned about. |
| [Why descriptors rather than a shared volume](descriptors.md) | The argument for passing descriptors, and what it costs. |
| [What the overhead measures at](overhead.md) | Where the fixed cost of a call comes from, and what was ruled out. |

Decisions that were argued rather than obvious are in [`adr/`](../../adr/README.md).
