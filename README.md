# HotCell

Run untrusted media conversion outside the application, in an unprivileged sibling container with no
network, and pass file descriptors to it rather than paths or bytes.

The threat is untrusted content parsed by libraries that cannot be made safe: libvips, ImageMagick,
LibreOffice, ffmpeg. Today they run inside the application process, where an exploit lands beside the
database credentials. HotCell moves them into a container that holds nothing worth stealing.

This repository holds three gems.

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both sides | The wire protocol, descriptor passing, payload validation, the error taxonomy. |
| `hotcell-client` | the application | `HotCell::Client`, cell registration, routing, instrumentation. |
| `hotcell-server` | the cell | The supervisor, the worker, `HotCell::Operation`, the container image. |

Two more gems, in [`basecamp/activestorage-hotcell`](https://github.com/basecamp/activestorage-hotcell),
wire this into Active Storage's transformer, analyzer, and previewers.

## Status

Under construction. Nothing here is released.

## Development

```
bundle install
rake            # every gem's suite
rake hotcell-core
```

The suite needs no container and no converter installed.

## Design

`HOTCELL-SPEC.md` in the design repository is the authority on the wire contract, the threat model, and
the measurements behind every limit.
