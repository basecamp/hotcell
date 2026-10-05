---
okf_version: "0.2"
title: "Reference manual"
description: "One page for each part of Hot Cell, for agents and for readers who want the details."
---

# Reference manual

This manual describes Hot Cell one topic per page. For an introduction and a quick start, see the
[README](../README.md).

Each page starts with
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
(OKF) frontmatter:

- `type`: `Reference` for a page that describes behavior, `Glossary` for the terms, `Design` for the
  rationale, and `Contributing` for the pages about working on Hot Cell itself.
- `title` and `description`: the page's name and one-line summary, which this index lists.
- `order`: optional. An index lists the pages that have an `order` first, in that order, and the rest by
  file name.
- `sources`: the code that the page describes. When that code changes, the page might need to change too.
  See [Keep the docs current](contributing/docs.md).

<!-- index -->

| Page | Description |
| --- | --- |
| [Concepts](concepts.md) | The terms the Hot Cell documentation uses: cell, supervisor, worker, slot, operation, client, tool, payload, inputs and outputs, and codes. |
| [Request lifecycle](request-lifecycle.md) | What happens between a call to perform_in_hotcell and its answer, step by step. |
| [Client API](client-api.md) | HotCell.register and its options, HotCell::Client, the errors a bad call raises, the boot checks, diagnosis, and the group the application shares with a cell. |
| [Operation API](operation-api.md) | HotCell::Operation's class and instance methods, run_tool, and the Input and Output descriptors that perform receives. |
| [Response codes](codes.md) | Every failure code and kill cause, whether each is permanent or transient, the exception classes the client raises, and what Active Storage records. |
| [Container](container.md) | Building the cell's image, every container flag and what it does, bounding OpenMP, and checking an accessory before and after a deploy. |
| [Scratch](scratch.md) | Where a cell stages files: the tmpfs, named volume, and host-mount layouts, and the boot sweep. |
| [Cell settings](cell-settings.md) | HotCell.limits: the scheduling settings and request limits with their defaults, the environment variables, the load order, and development mode. |
| [Tuning](tuning.md) | Which measurement sets each cell number, the constraints between the numbers, and how to use bin/load. |
| [Observability](observability.md) | Recommended alerts, the perform.hot_cell notification, the application log line, Yabeda metrics, cell metrics, the cell log schema, and the healthchecks. |
| [Conformance](conformance.md) | What bin/conformance checks about a cell image, and what it cannot check. |
| [Active Storage operations](active-storage.md) | The Active Storage client classes, the cell operations that serve them, how their failures are retried, and the limits each declares. |
| [ImageMagick](imagemagick.md) | ImageMagick's MAGICK_* resource limits, how they interact with a cell, and the formulas to set them. |
| [Contributing to Hot Cell](contributing/index.md) | Working on the gems themselves: setup, tests, releases, keeping the docs current, the experiments and measurements the design rests on, and the decision records. |
| [Design](design/index.md) | The intent behind Hot Cell's design: the threat model, the invariants, worker isolation, and passing file descriptors. |

<!-- indexstop -->
