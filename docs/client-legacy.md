---
type: Reference
title: "Legacy client"
description: "HotCell::Client::Legacy, the dependency-free client for legacy Ruby versions: its options, the failures it raises, and how it differs from hotcell-client."
sources:
  - hotcell-client-legacy/lib/hot_cell/client/legacy.rb
---

# Legacy client

Many legacy Rails applications run a Ruby version that `hotcell-client` doesn't support. To run custom operations
in a cell from one of those applications, use `hotcell-client-legacy`. It works on legacy Ruby versions, back to
1.9.3, and uses only the standard library.

## Call a cell

1. Add `hotcell-client-legacy` to your application's Gemfile.
2. Create a client with the path to the cell's `work.sock`.
3. Call `perform` with the operation's name, the input and output files, and a payload.

```ruby
require "hotcell-client-legacy"

client = HotCell::Client::Legacy.new("/run/hotcell/images/work.sock", timeout: 30, group: 10001)

File.open(source, "rb") do |input|
  File.open(destination, "wb") do |output|
    client.perform "images.transform", [input], [output], "format" => "png"
  end
end
```

### Options

| Option | Default | Description |
| --- | --- | --- |
| `timeout:` | `30` | Seconds to wait for the whole call: connecting, sending, and reading the answer. Set it higher than the cell's `answer_within`. See [Tuning](tuning.md#make-the-timeouts-agree). |
| `group:` | none | The cell's gid. The client gives each input and output this group, with mode `0640` for inputs and `0620` for outputs. Leave it unset only when the application and the cell run as one user. See [The shared group](client-api.md#the-shared-group). |

**Caution:** The client doesn't restore a file's group or mode after the call.

### `perform` arguments

| Argument | Description |
| --- | --- |
| `operation` | The operation's routing name. |
| `inputs` | An IO or an `Array` of IOs. Open each one read-only, on a regular file, without `O_APPEND`. |
| `outputs` | An IO or an `Array` of IOs. Open each one write-only, on a regular file, without `O_APPEND`. |
| `payload` | Optional. A `Hash` of JSON values. |

`perform` returns the operation's result, a `Hash` with `String` keys.

## Handle failures

`perform` raises one of these classes. Neither descends from the other, so rescue each one by name.

| Class | Raised when |
| --- | --- |
| `HotCell::Client::Legacy::PermanentFailure` | The cell marks the failure permanent. A retry fails the same way. |
| `HotCell::Client::Legacy::TransientFailure` | Any other failure. A retry might succeed. |

Both classes include `HotCell::Client::Legacy::Verdict`, so you can rescue `Verdict` to catch either one.
Call `hot_cell_failure` on the exception to read the failure, as with `hotcell-client`. See
[Exception classes](codes.md#exception-classes). The failure has these attributes:

| Attribute | Description |
| --- | --- |
| `code` | The failure's code. See [Response codes](codes.md). |
| `permanent?` | `true` if the cell marked the failure permanent, and `false` otherwise. |
| `cause`, `signal`, `error_class`, `message`, `stderr` | The fields that the cell sent, or `nil`. Each is a `String` of at most 512 bytes, with invalid UTF-8 removed. `stderr` keeps its last 512 bytes. |

The text in the failure comes from the cell. Treat it as untrusted.

When the client gets no usable answer, it raises `TransientFailure` with one of these codes:

| Code | Raised when |
| --- | --- |
| `timeout` | The deadline passed. |
| `unavailable` | The socket is missing or refuses the connection, the cell closed the connection without answering, or the answer isn't valid. |

## Differences from `hotcell-client`

Unlike `hotcell-client`, the legacy client doesn't do the following:

- Integrate with Rails or Active Storage, register cells, publish `perform.hot_cell`, or report metrics.
- Raise your own exception classes. Rescue its classes and raise yours.
- Check files or the payload before sending. The cell checks the files and answers `invalid`.
  `JSON.generate` turns a `Symbol` or a `Time` in the payload into a `String`.
- Treat a success with empty outputs as a failure. The legacy client returns the result.
