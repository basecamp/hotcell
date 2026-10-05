---
title: "Design"
description: "The intent behind Hot Cell's design: the threat model, the invariants, worker isolation, and passing file descriptors."
---

# Design

These pages describe the intent behind Hot Cell's design and implementation: why the work moves out of your
application's process, what a cell defends against, and the properties that the whole design exists to
hold. For how to use the gems, see the [reference manual](../index.md).

<!-- index -->

| Page | Description |
| --- | --- |
| [Threat model](threat-model.md) | What Hot Cell is, the problem it solves, and what a cell is defended against. |
| [Invariants](invariants.md) | The numbered properties the design exists to hold. Code and tests cite them by number. |
| [Worker isolation](worker-isolation.md) | What one worker can and cannot reach of another, and the residuals that remain. |
| [Passing file descriptors](descriptors.md) | The argument for passing file descriptors instead of sharing a directory, and what it costs. |

<!-- indexstop -->
