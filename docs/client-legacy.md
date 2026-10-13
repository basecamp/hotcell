---
type: Reference
title: "Legacy client"
description: "HotCell::Client::Legacy, the dependency-free client for legacy Ruby versions: its options, the response it returns, the failures it raises, and how it differs from hotcell-client."
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

`perform` returns a `HotCell::Client::Legacy::Response`. See [Read the response](#read-the-response).

## Read the response

A `Response` holds the outcome of one call:

| Attribute | Description |
| --- | --- |
| `result` | The operation's result, a `Hash` with `String` keys. `nil` on failure. |
| `failure` | The failure, or `nil` on success. See [Handle failures](#handle-failures). |
| `ok?` | `true` on success, and `false` otherwise. |
| `timing` | The timings that the cell reported, such as `queued_ms` and `perform_ms`, in a `Hash` with `String` keys. An operation can add its own keys, and any key can be missing. Empty when the answer has no `timing` object, or when the client got no usable answer. |
| `duration_ms` | The milliseconds that the client measured across the call: connecting, sending, and reading the answer. |

```ruby
response = client.perform "images.transform", [input], [output], "format" => "png"
response.result               # => { "width" => 800, "height" => 600 }
response.timing["perform_ms"] # => 38.2
response.duration_ms          # => 41.7
```

`duration_ms` minus `perform_ms` is transport plus queueing. Track the two separately. See
[Per-call notification](observability.md#per-call-notification).

The keys and values in `timing` come from the cell. Treat them as untrusted.

## Handle failures

`perform` raises one of these classes. Neither descends from the other, so rescue each one by name.

| Class | Raised when |
| --- | --- |
| `HotCell::Client::Legacy::PermanentFailure` | The cell marks the failure permanent. A retry fails the same way. |
| `HotCell::Client::Legacy::TransientFailure` | Any other failure. A retry might succeed. |

Both classes include `HotCell::Client::Legacy::Failure::Exception`, so you can rescue `Failure::Exception` to catch either one.
Call `hot_cell_failure` on the exception to read the failure, as with `hotcell-client`. See
[Exception classes](codes.md#exception-classes). Call `hot_cell_response` to read the whole
[response](#read-the-response), with its `timing` and `duration_ms`. The failure has these attributes:

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

## Read a cell's description and metrics

`describe` and `metrics` ask the cell's `control.sock`, in the same directory as the `work.sock` that you
gave the client. Each returns a `Response`, and raises as `perform` does.

```ruby
client.describe.result # => { "v" => 1, "server_version" => "1.1.0", "operations" => [...], "groups" => [...], ... }
client.metrics.result  # => { "running" => 0, "queued" => 0, "killed_by" => {}, ... }
```

The control socket is local to the cell's host, so call these from a process on that host. For the fields
that `metrics` reports, see [Cell metrics](observability.md#cell-metrics).

## Differences from `hotcell-client`

Unlike `hotcell-client`, the legacy client doesn't do the following:

- Integrate with Rails or Active Storage, register cells, or publish `perform.hot_cell`.
- Raise your own exception classes. Rescue its classes and raise yours.
- Check files or the payload before sending. The cell checks the files and answers `invalid`.
  `JSON.generate` turns a `Symbol` or a `Time` in the payload into a `String`.
- Treat a success with empty outputs as a failure. The legacy client returns the result.
