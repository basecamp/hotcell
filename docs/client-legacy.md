---
type: Reference
title: "Legacy client"
description: "HotCell::Client::Legacy, the dependency-free client for legacy Ruby versions: its options, the failures it raises, and what it leaves out."
sources:
  - hotcell-client-legacy/lib/hot_cell/client/legacy.rb
---

# Legacy client

`hotcell-client-legacy` calls a cell from an application that can't run `hotcell-client`, which needs Ruby 3.3
or later and Active Support. It's one file that uses only the standard library, and it runs on legacy Ruby
versions as old as 1.9.3. The cell runs its own Ruby in its own container, so nothing changes on the cell side.

The code is in
[`hotcell-client-legacy/lib/hot_cell/client/legacy.rb`](../hotcell-client-legacy/lib/hot_cell/client/legacy.rb).

## Call a cell

```ruby
require "hotcell-client-legacy"

client = HotCell::Client::Legacy.new("/run/hotcell/images/work.sock", timeout: 30, group: 10001)

File.open(source, "rb") do |input|
  File.open(destination, "wb") do |output|
    client.perform "images.transform", [input], [output], "format" => "png"
  end
end
```

`HotCell::Client::Legacy.new(socket_path, options = {})` takes the path to the cell's `work.sock` and these
options:

| Option | Default | Description |
| --- | --- | --- |
| `timeout:` | `30` | Seconds that the whole call may take: connecting, sending the request, and reading the answer. It must be more than the cell's `answer_within`. See [Tuning](tuning.md#make-the-timeouts-agree). |
| `group:` | none | The cell's gid. Before it sends a request, the client puts each input and output in this group and sets mode `0640` on each input and `0620` on each output, as `hotcell-client` does. Leave it unset only where the application and the cell run as one user. See [The shared group](client-api.md#the-shared-group). |

`perform(operation, inputs, outputs, payload = {})` sends one request and returns the operation's result, a
`Hash` with `Symbol` keys. It accepts the following:

- `operation`: the routing name of the operation.
- `inputs` and `outputs`: one IO, or an `Array` of IOs. Each input must be open read-only and each output
  write-only, and each must be a regular file not opened with `O_APPEND`.
- `payload`: a `Hash` that JSON can carry.

**Caution:** As with `hotcell-client`, the client doesn't restore a file's group or mode after the call.

## Failures

`perform` raises `HotCell::Client::Legacy::PermanentFailure` when the cell's answer says `permanent: true`, and
`HotCell::Client::Legacy::TransientFailure` otherwise. For what each side of that split means, see
[Response codes](codes.md). The two classes share no ancestor but `StandardError`, so rescue each by name.

Both classes have these attributes:

| Attribute | Description |
| --- | --- |
| `code` | The failure's code, such as `unreadable` or `capacity`. |
| `error` | The failure's fields from the cell's answer, as a `Hash` with `Symbol` keys: `permanent`, and whichever of `code`, `cause`, `signal`, `class`, `message` and `stderr` the cell sent. |

The client makes each of those fields but `permanent` a `String`, caps it at 512 bytes, and removes bytes
that aren't valid UTF-8, as `hotcell-client` does. `stderr` keeps its last 512 bytes, where the fatal line is. The text still comes from
the cell, so treat it as untrusted.

A call that gets no usable answer raises `TransientFailure` with one of these codes:

| Code | Raised when |
| --- | --- |
| `timeout` | The deadline passed while the client was connecting, sending, or reading. |
| `unavailable` | The socket doesn't exist or refuses the connection, the connection closed with no answer, or the answer isn't a valid response. |

## What the legacy client leaves out

If you need any of the following, use `hotcell-client`:

- Rails integration, cell registration, Active Storage support, the `perform.hot_cell` notification, and
  metrics.
- Your own exception classes. The legacy client raises its own; rescue them and raise yours.
- Checks before sending. The legacy client doesn't check access modes, payload values, or the request's size.
  The cell checks the descriptors and the request, and answers `invalid`, which is permanent. `JSON.generate`
  turns a `Symbol` or a `Time` in the payload into a `String` instead of raising.
- Refusing an empty output. `hotcell-client` raises a transient failure when a cell reports success and the
  outputs hold no bytes. The legacy client returns the result.
