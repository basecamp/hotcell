# HotCell — design

The code is the specification. This document holds the parts of the design that reading the code cannot
give you: why the work moves out of the application process at all, what a cell is defended against, the
invariants the whole thing exists to hold, and the facts that were measured rather than reasoned about.

It deliberately does not describe the gems' APIs. That description used to live here, it went stale as
soon as the code moved, and worse, its errors propagated back into the code's own comments. Behavior
belongs in the code and its tests; [CONTRIBUTING.md](../CONTRIBUTING.md) covers working on them, and
[docs/DEPLOYMENT.md](DEPLOYMENT.md) covers running one.
