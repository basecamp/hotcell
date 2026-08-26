# HotCell changelog

This changelog covers five gems, which release together on the same version:

- `hotcell-core`
- `hotcell-client`
- `hotcell-server`
- `activestorage-hotcell-client`
- `activestorage-hotcell-server`

## next / unreleased

### HotCell::Client

#### Breaking

* `HotCell.describe_cells` no longer warns about a client whose operation the cell does not carry, and `HotCell.clients` is gone with it. The check could not tell a client the application calls from one it merely loaded, so a cell carrying a subset of what a gem ships warned on every boot. A request for an operation a cell does not carry is refused as `unsupported`, naming the operation, and that failure is transient and reaches the application's error reporting. An application that wants a boot check can write one over its own configuration.


## v0.2.0 / 2026-08-25

### HotCell::Client and HotCell::Server

#### Security

* The file-size verdict is now earned from the failed write rather than read off a signal. Workers share a uid, so one worker could signal another and have the supervisor write a permanent `fsize` or `memory` judgment against the victim's unrelated input, which Active Storage would then cache forever. Every signal but the supervisor's own deadline kill is now `crashed` and transient. (#25)
* Each request now gets a `$HOME` name no earlier request held, under a slot directory whose mode is reasserted first. A tool that reached code execution could `chmod 0500` its own configuration directory, defeating both the worker's delete and the supervisor's rename, and hand the next request the tree that had refused to go. (#22)
* A failed scratch removal is retried with the modes put back, and logs `slot.unswept` when it still fails. A `chmod 0500` on a directory a conversion wrote left one tree per request on the tmpfs, readable by every later request on the slot, and `sweep` reported nothing. (#22)

#### Fixed

* `Cell#describe` reads the description inside a rescue. A response with a correctly framed shape but the wrong types raised out of `describe_cells`, which the README recommends calling from `after_initialize` where nothing rescues it — so a cell answering badly could stop a Rails application from booting. An unreadable description is now logged and ignored, which is what an unreachable cell already returned. (#29)
* `HotCell.register` raises `ConfigurationError` unless `timeout` and `control_timeout` are positive and finite. A `nil` timeout built no deadline at all, so a cell that accepted a connection and never answered held the caller for good. (#34)
* The installer writes `hotcell/operations/.keep` rather than shipping it as a template. `hotcell-client.gemspec` selects `Dir["lib/**/*"]`, which does not match a dotfile, so the published v0.1.0 installer wrote a scaffold whose generated `Dockerfile` could not build. (#26)

## v0.1.0 / 2026-08-19

- Birthday!
