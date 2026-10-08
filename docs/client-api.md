---
type: Reference
title: "Client API"
order: 3
description: "HotCell.register and its options, HotCell::Client, the errors a bad call raises, the boot checks, diagnosis, and the group the application shares with a cell."
sources:
  - hotcell-client/lib/hot_cell/cells.rb
  - hotcell-client/lib/hot_cell/cell.rb
  - hotcell-client/lib/hot_cell/client.rb
  - hotcell-client/lib/hot_cell/diagnosis.rb
  - hotcell-client/lib/hot_cell/failures.rb
  - hotcell-core/lib/hot_cell/errors.rb
  - hotcell-core/lib/hot_cell/payload.rb
---

# Client API

This page describes the application side of Hot Cell: registering cells with `HotCell.register`, writing
`HotCell::Client` subclasses, the boot checks, and the group that the application shares with each cell.
For the cell side of the call, see [Operation API](operation-api.md).

The code lives in [`hotcell-client/lib/hot_cell/`](../hotcell-client/lib/hot_cell/), mainly `cells.rb`,
`cell.rb`, and `client.rb`.

## Configure Hot Cell

Configure Hot Cell in an initializer. Pass exception classes that fit your domain; your own base classes
can be useful when you wrap an existing library.

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]              # unset turns every cell off
HotCell.group = ENV["HOTCELL_GROUP"]            # the cell's gid; unset where both sides are one user

HotCell.register "images",
  timeout: 30,
  permanent: ActiveStorage::PreviewError,
  transient: MyApp::ConversionTemporarilyUnavailable,
  on_contract_skew: ->(error, cell) { Sentry.capture_exception(error) }
```

| Setting | Default | Description |
| --- | --- | --- |
| `HotCell.root` | none | The parent directory that cell names resolve under. A cell's sockets are in `<root>/<name>`. |
| `HotCell.group` | none | The gid that both sides hold, so that a cell can open a caller's file by name. Set it to the cell's gid. A value that isn't a number raises `HotCell::ConfigurationError`. Leave it unset only where both sides already run as one user, which is how development runs. See [The shared group](#the-shared-group). |
| `HotCell.diagnostics_controller_parent` | `"ActionController::Base"` | The name of the superclass of `HotCell::DiagnosticsController`. Set it in an initializer, because the controller reads it when it loads. See [Observability](observability.md#rails-healthcheck). |
| `HotCell.logger` | a `Logger` on standard error | Where the boot checks write their warnings. |

### Turn cells off

When `HotCell.root` is unset and a cell has no `dir:`, the cell is off: `enabled?` returns `false`, and
`perform_in_hotcell` raises `HotCell::CellNotConfigured`. Hot Cell has no automatic in-process fallback.
A caller that wants one checks `enabled?` and takes its old path. This is how an application rolls out a
cell as a configuration change rather than a release.

The shipped Active Storage classes don't check `enabled?`. With no root, every variant, analysis, and
preview that they handle raises `HotCell::CellNotConfigured`.

## Register a cell

`HotCell.register(name, **options)` registers one cell. Call it once for each cell, at boot.

| Option | Default | Description |
| --- | --- | --- |
| `dir:` | `<HotCell.root>/<name>` | An explicit socket directory for this cell. To make a change of path a configuration change instead of a deploy, pass a lambda: the client resolves the directory on every call. |
| `timeout:` | `30` | Seconds that this caller waits for an answer to a work request. It must be more than the cell's `answer_within`. See [Tuning](tuning.md#make-the-timeouts-agree). |
| `control_timeout:` | `5` | Seconds that this caller waits for `describe` or `metrics`. The supervisor answers both inline, with no fork and no queue, so keep this short and don't raise it toward `timeout`. It bounds app boot when a cell accepts connections and never answers, and it lets a health check report a stuck cell instead of waiting out a work timeout. |
| `permanent:` | `HotCell::PermanentFailure` | The exception class that the client raises for a permanent failure. See [Response codes](codes.md#exception-classes). |
| `transient:` | `HotCell::TransientFailure` | The exception class that the client raises for a transient failure. It must not descend from `permanent:`. |
| `on_contract_skew:` | none | A callable, `->(error, cell)`, that the client calls when a cell answers `protocol`, before it raises. Use it to make a protocol version mismatch visible to an application that rescues broadly. |

`timeout:` and `control_timeout:` must be positive, finite numbers. `register` raises
`HotCell::ConfigurationError` for anything else, including `nil`, so a bad value stops the boot rather
than leaving the wait for a cell to decide. `register` also raises `HotCell::ConfigurationError` when
`transient:` descends from `permanent:`.

Both timeouts bound the answer, not the connection. See [Boot checks](#boot-checks).

### Look up a cell

| Method | Description |
| --- | --- |
| `HotCell.cell(name)` | Returns the registered cell. Raises `HotCell::UnregisteredCell` if no cell has that name. |
| `HotCell.cell?(name)` | Returns whether a cell with that name is registered. |
| `HotCell.cells` | Returns a `Hash` of every registered cell, by name. |

## Write a client

A client is a subclass of `HotCell::Client`:

```ruby
class TransformImage < HotCell::Client
  hotcell "images"                # the cell that serves this call, by registered name
  operation "images.transform"    # the routing name an operation must answer to
end

result = TransformImage.perform_in_hotcell source, destination, format: "png"
```

| Class method | Description |
| --- | --- |
| `hotcell(name)` | Names the registered cell that serves this client. A subclass inherits it. |
| `operation(name)` | Sets the routing name. A subclass doesn't inherit it. By default, the name derives from the class path the same way an operation's does. See [Operation API](operation-api.md#operationname--nil). |
| `perform_in_hotcell(inputs, outputs, payload = {})` | Sends the request and blocks until the cell answers or `timeout` passes. Returns the operation's result. |
| `enabled?` | Returns whether the client's cell has a socket directory. |
| `registered?` | Returns whether the client's cell is registered. Use it in a boot hook that must not raise in an application that hasn't written its initializer yet. |

`perform_in_hotcell` accepts the following:

- `inputs` and `outputs`: one IO, or an `Array` of IOs. Each input must be open read-only and each output
  write-only, and each must be a regular file not opened with `O_APPEND`. A descriptor that fails these
  checks raises `HotCell::AccessModeError` before anything is sent.
- `payload`: a `Hash` that JSON can carry faithfully. A value that JSON would change, such as a `Symbol`
  or a `Time`, raises `HotCell::SerializationError` before anything is sent.

On failure, `perform_in_hotcell` raises the cell's `permanent:` or `transient:` class. Either way, it
publishes a `perform.hot_cell` notification. See
[Observability](observability.md#per-call-notification).

The exception carries the failure. Call `hot_cell_failure` on it to read the failure's `code` and `cause`,
or rescue `HotCell::Verdict` to catch it whatever classes you registered. See
[Response codes](codes.md#exception-classes).

### Errors that the client raises for a bad call

These classes descend from `HotCell::Error`. The client raises them for a mistake in the call itself,
outside its transport rescue, so an application whose transient class descends from `IOError` can't
retry them forever.

| Class | Raised when |
| --- | --- |
| `HotCell::ConfigurationError` | Either side is configured wrongly. Raised at boot where possible. |
| `HotCell::UnregisteredCell` | A client names a cell that isn't registered. |
| `HotCell::CellNotConfigured` | A client calls a cell that has no socket directory. |
| `HotCell::AccessModeError` | A descriptor has the wrong access mode, isn't a regular file, or is open with `O_APPEND`. |
| `HotCell::SerializationError` | A payload or result value can't travel as JSON faithfully. |
| `HotCell::MessageError` | A message is unparseable, too long, or missing a field. |
| `HotCell::ReadTimeout` | A peer stopped partway through a message. |

## Boot checks

`HotCell.describe_cells` asks each registered cell for `describe` over its control socket. Call it once at
boot, after registering:

```ruby
Rails.application.config.after_initialize { HotCell.describe_cells }
```

It returns each cell's description, by name, and warns through `HotCell.logger` about the following:

- This process doesn't hold `HotCell.group`. This check is local and needs no cell, so it reports a
  missing `group-add` even when every cell is down.
- The cell is unreachable.
- The client's `timeout` doesn't clear the cell's `answer_within`.
- The cell doesn't run in `HotCell.group`. `describe` reports the groups that a cell holds. The number in
  your deploy file and the gid built into the cell's image come from different places, so nothing else
  catches a cell image whose gid moved. A cell too old to report its groups gets no warning.
- The cell's `hotcell-server` version differs from this `hotcell-client` version.

`describe_cells` warns and never raises. A cell that's down at boot is a degraded deployment rather than a
broken one.

The description comes from the process that runs untrusted content, so the client reads it inside a
rescue. The client logs and ignores an answer that it can't use, and treats the cell as one that answered
nothing. This catches a misdeployment, not a compromised cell: a compromised cell can send a well-formed
description that is false, and the client can't tell.

The rescue has the following limits:

- It covers what a cell says, not a cell that never answers at boot. `control_timeout` bounds the answer
  and not the connection, so a listener that stops accepting until its backlog fills can hold the
  connect. See [#20](https://github.com/basecamp/hotcell/issues/20).
- It covers what raises at boot, not what a value does later. `describe_cells` returns the description
  whole, so it can hold a string that isn't valid UTF-8, or a number that parses to infinity. Validate the
  returned description for whatever you do with it: serializing, matching, storing, and rendering can all
  raise on these values.

### Diagnose cells

`HotCell.diagnose(work: false)` runs checks against every registered cell and returns a
`HotCell::Diagnosis`. Call `as_json` for the result: the time, the host, `healthy`, and each cell's checks.

| Check | Socket | Description |
| --- | --- | --- |
| `describe` | control | The cell answers `describe`. |
| `metrics` | control | The cell answers `metrics`. |
| `echo` | work | A `health.echo` round trip. Only with `work: true`. |
| `reopen` | work | A `health.reopen` round trip, which proves that the cell can open an input by name. Only with `work: true`. |

`healthy` is true when at least one cell is registered and every check passes. The work checks need
`require "hot_cell/health_operations"` in one of the cell's operation files. See
[Observability](observability.md#rails-healthcheck) for the controllers that serve these checks.

## The shared group

Set `HotCell.group` to the cell's gid, and put the application in that group:

```yaml
# config/deploy.yml — the app
servers:
  web:
    options:
      group-add: 10001
```

The group is required for the following reasons:

- **Connecting.** The cell creates both sockets with mode `0660`, owned by its own user and group. A UNIX
  socket needs write permission to connect, so without the group, the application can't reach the cell.
- **Opening files by name.** An operation that hands a tool a filename doesn't copy the input. It opens
  the descriptor again as `/dev/fd/N`. That's a new open, and the kernel checks it against the cell's
  user, not the caller's. The two sides don't share a uid, so a mode `0600` file that the application owns
  gives `EACCES`. An Active Storage tempfile is such a file, and every shipped Active Storage operation
  hands a tool a filename.

Without the group, every call fails immediately with `EACCES` from `connect`. There's no partly working
state to mistake for healthy, and `HotCell.describe_cells` reports it at boot, before any traffic depends
on it.

### What the client does with the group

The client puts each descriptor in the group and sets its mode before sending: `0640` for an input and
`0620` for an output. It does this through the open file, with `fchown` and `fchmod`, so it names no path.

**Caution:** The client doesn't restore the group or the mode. The file that you pass keeps the cell's
group and the new mode after the call returns, so a `0600` file of your own comes back readable by that
group. Active Storage passes tempfiles and unlinks them, so this doesn't matter there. If you write your
own client, pass files that you're willing to share with the cell's group, and don't pass a file whose
permissions something else depends on.

These modes enforce [invariant 4](design/invariants.md): a cell can read an input and write an output,
and can't write an input or read an output. The cell can't widen either mode, because it doesn't own the
files, and `cap-drop ALL` leaves it no capability that overrides a mode. The application must own the
files and be in the group to set the group at all.

### Don't share a uid instead

Sharing a uid between the application and the cell is the obvious shortcut, and it costs two things:

- The cell would own the files, so it could set any mode, and inputs and outputs would stop being
  one-way.
- A cell that escaped its container would run as the application's own user on the host, where it can
  read the environment of the application's processes.

Keep the uids separate and share only the group.
