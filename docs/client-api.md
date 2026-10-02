# Client API

#### Configure the application

The initializer does not change shape: register the cell your client classes name, with exception
classes that fit the domain. Nothing under `config.active_storage` applies. This example
additionally declares custom base classes for exceptions, which can be useful when wrapping existing
libraries.

```ruby
HotCell.register "images",
  permanent: MyApp::UnreadableImage,
  transient: MyApp::ConversionTemporarilyUnavailable
```

Leaving `HOTCELL_ROOT` unset turns every cell off -- `enabled?` answers false, and
`perform_in_hotcell` raises `HotCell::CellNotConfigured`. There is no automatic in-process fallback:
a caller that wants one checks `enabled?` and takes its old path, which is how an application rolls
a cell out as a configuration change rather than a release.

## Application settings

Per registered cell. They set how the application responds to what a cell answers.

```ruby
HotCell.root = ENV["HOTCELL_ROOT"]              # unset turns every cell off
HotCell.group = ENV["HOTCELL_GROUP"]            # the cell's gid; unset where both sides are one user

HotCell.register "images",
  timeout: 30,
  permanent: ActiveStorage::PreviewError,
  transient: MyApp::ConversionTemporarilyUnavailable,
  on_contract_skew: ->(error, cell) { Sentry.capture_exception(error) }
```

| Setting | Default | What it does |
| --- | --- | --- |
| `HotCell.root` | — | The parent directory that cell names resolve under. When it is unset, every cell is off and callers run in process. |
| `HotCell.group` | — | The group both sides hold, so a cell can open a caller's file by name. Set it to the cell's gid. Unset is for an installation whose two sides already run as one user, which is how development runs. See "The group both sides share". |
| `dir:` | from `root` | An explicit socket directory for one cell. Give a lambda to make a change of path a configuration change instead of a deploy. |
| `timeout:` | `30` | Seconds this caller waits for an answer to a work request. It must clear the cell's `answer_within`. A positive, finite number: `register` raises `ConfigurationError` on anything else, including `nil`, which stops the boot rather than leaving the wait for a cell to decide. |
| `control_timeout:` | `5` | Seconds this caller waits for `describe` or `metrics`. The supervisor answers both inline, with no fork and no queue, so this is short on purpose and must not be raised toward `timeout`. It is what bounds app boot when a cell accepts connections and never answers, and what lets a health check report a wedged cell instead of waiting out a work timeout. Bounded like `timeout:`, and refused the same way. |
| `permanent:`, `transient:` | the gem's classes | The exception classes the application raises for each side of the split. `transient` must not descend from `permanent`, and the client refuses to start if it does. |
| `on_contract_skew:` | — | Called when a cell answers `protocol`, so a protocol version mismatch is visible to an application that rescues broadly. |

### The socket's file mode

The cell creates both sockets `0660`, owned by its own user and group. A Unix socket needs write
permission to connect, so the shared group in the next section is what lets your application reach a cell
at all. It is not optional.

Without it every call fails with `EACCES` from `connect`, and `HotCell.describe_cells` says so at boot,
before any traffic depends on it.

### The group both sides share

Set `HotCell.group` to the cell's gid, and put the application in that group:

```yaml
# config/deploy.yml — the app
servers:
  web:
    options:
      group-add: 10001
```

**Why it is needed.** Two reasons.

The sockets are `0660` and owned by the cell's user and group, so without the group your application
cannot connect to a cell at all.

And an operation that hands a tool a filename does not copy the input. It re-opens the descriptor as
`/dev/fd/N`. That is a fresh open, and the kernel rechecks it against the **cell's** user rather than the
caller's. The two sides do not share a uid, so a mode `0600` file the application owns gives `EACCES`. An
Active Storage tempfile is exactly that.

Every shipped Active Storage operation hands a tool a filename, so this applies to all of them.

**What the client does with it.** It puts each descriptor in the group and sets the mode on the way out:
`0640` for an input, `0620` for an output. It does this through the open file rather than a path, so it
names nothing.

**It sets those and does not put them back.** The file you hand over keeps the cell's group and the new
mode after the call returns, so a `0600` file of your own comes back readable by that group. Active
Storage hands over tempfiles and unlinks them, so this is invisible there. If you write your own client,
hand over files you are willing to share with the cell's group, and do not pass one whose permissions
something else depends on.

**What that buys, and what it does not.** A cell may read an input and write an output. It may not write
an input or read an output, and it cannot widen either, because it does not own these files and
`cap-drop ALL` leaves it no capability that overrides a mode. The application must own them and be in the
group, which is what lets it set the group at all.

**Do not share a uid instead.** It is the obvious shortcut and it costs two things. The cell would own the
files, so it could set any mode it liked and the one-way rule would stop holding. And a cell that escaped
its container would land on the application's own user on the host, where it can read the environment of
the application's processes. Keep the uids apart and share only the group.

**How it fails.** Immediately, on every call, with `EACCES` from `connect`. There is no partly working
state to misread as healthy.

**What warns first.** `HotCell.describe_cells` checks two things at boot, and warns rather than raising,
like every other boot check here.

- **Whether this process holds `HotCell.group`.** A missing `group-add` is then visible before any traffic
  depends on it. This check is local and needs no cell, so it reports even when every cell is down.
- **Whether the cell runs in that group.** `describe` reports the groups a cell holds, and the client
  compares them. The number lives in your deploy file and the cell's gid is baked into an image built
  somewhere else, so nothing else would catch a cell image that moved its gid. A cell too old to report
  them says nothing.

Neither check trusts what the cell says. The process answering runs untrusted content, so its description
is read inside a rescue: an answer this client cannot use is logged and ignored, and the cell is treated as
one that answered nothing. What that catches is a misdeployment, not a compromised cell — a cell that has been taken over can answer a perfectly well-formed
description that is simply false, and nothing on this side can tell.

What the rescue covers is what a cell *says*. It does not cover a cell that never answers at boot:
`control_timeout` bounds the answer and not the connection, so a listener that stops accepting until its
backlog fills can hold the connect. That is [#20](https://github.com/basecamp/hotcell/issues/20).

And it covers what raises at boot, not what a value does later. A description is handed back whole, so a
cell can put a string in it that is not valid UTF-8, or a number that parses to an infinity. Neither raises
here. The whole returned description stays untrusted: validate it for whatever you do with it — serializing,
matching, storing or rendering are all places these values raise.
