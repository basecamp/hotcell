# Architecture decision records

Decisions that were argued rather than obvious, kept so the argument does not have to be rerun. Each record
states what was decided, what it was decided against, and what it costs.

One file per decision, numbered in the order they were accepted, named `NNNN-what-was-decided.md`. A record
is written when the decision is made and is not edited afterwards. A later decision that changes an earlier
one gets its own record and marks the earlier one superseded.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-reuse-workers-across-requests.md) | A worker may serve more than one request, and serves one by default | Accepted |
| [0002](0002-keep-the-warm-slot-home.md) | Keep the warm slot home, as an accepted trade-off | Superseded by [0003](0003-remove-the-persistent-slot-home.md) |
| [0003](0003-remove-the-persistent-slot-home.md) | Remove the persistent slot home; a request's `$HOME` is made and removed with it | Accepted |
