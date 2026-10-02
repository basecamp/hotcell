---
okf_version: "0.2"
title: "HotCell reference manual"
description: "One page for each part of HotCell, for agents and for readers who want the details."
---

# HotCell reference manual

This manual describes HotCell one topic per page. For an introduction and a quick start, see the
[README](../README.md).

Each page starts with [OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
frontmatter:

- `type`: `Reference` for a page that describes behavior, `Glossary` for the terms, and `Design` for the
  rationale.
- `title` and `description`: the page's name and one-line summary, which this index lists.
- `sources`: the code that the page describes. When that code changes, the page might need to change too.
  See [Keep the docs current](../AGENTS.md#keep-the-docs-current).

<!-- index -->

| Page | Description |
| --- | --- |
| [Active Storage operations](active-storage.md) | The Active Storage client classes, the cell operations that serve them, how their failures are retried, and the limits each declares. |
| [Cell settings](cell-settings.md) | HotCell.limits: the scheduling settings and request limits with their defaults, the environment variables, the load order, and development mode. |
| [Client API](client-api.md) | HotCell.register and its options, HotCell::Client, the errors a bad call raises, the boot checks, diagnosis, and the group the application shares with a cell. |
| [Response codes](codes.md) | Every failure code and kill cause, whether each is permanent or transient, the exception classes the client raises, and what Active Storage records. |
| [Concepts](concepts.md) | The terms the HotCell documentation uses: cell, supervisor, worker, slot, operation, client, tool, payload, inputs and outputs, and codes. |
| [Conformance](conformance.md) | What bin/conformance checks about a cell image, and what it cannot check. |
| [Container](container.md) | Building the cell's image, every container flag and what it does, bounding OpenMP, and checking an accessory before and after a deploy. |
| [ImageMagick](imagemagick.md) | ImageMagick's MAGICK_* resource limits, how they interact with a cell, and the formulas to set them. |
| [Observability](observability.md) | Recommended alerts, the perform.hot_cell notification, the application log line, Yabeda metrics, cell metrics, the cell log schema, and the healthchecks. |
| [Operation API](operation-api.md) | HotCell::Operation's class and instance methods, run_tool, and the Input and Output descriptors that perform receives. |
| [Request lifecycle](request-lifecycle.md) | What happens between a call to perform_in_hotcell and its answer, step by step. |
| [Scratch](scratch.md) | Where a cell stages files: the tmpfs, named volume, and host-mount layouts, and the boot sweep. |
| [Tuning](tuning.md) | Which measurement sets each cell number, the constraints between the numbers, and how to use bin/load. |
| [Design](design/index.md) | The threat model, the invariants, worker isolation, and the facts established by experiment: what the code cannot tell you. |

<!-- indexstop -->
