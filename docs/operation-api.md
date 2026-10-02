# Operation API

#### Write an operation

The client class in the application and the matching operation class in the cell share a routing
name. The fixed signature of the `#perform` method -- inputs, outputs, payload -- is the contract
for what crosses the socket. Descriptors travel as-is (without additional copies) and the payload
travels as one JSON object.

In the application, the client class and call site might look like:

``` ruby
class TransformImage < HotCell::Client
  hotcell "images"                # the cell that serves this call, by registered name
  operation "images.transform"    # the routing name an operation must answer to
end

# source and destination are Files the app already opened. This is a blocking call that waits for
# a response from the cell.
TransformImage.perform_in_hotcell source, destination,
                                  format: "png",
                                  operations: { resize_to_limit: [ 800, 600 ] }
```


The operation will run in the cell. Declare the routing name and the limits, hook library loading,
and `#perform`:

```ruby
require "active_support"
require "active_support/core_ext/numeric"   # for 30.seconds and 1280.megabytes

class TransformImageOperation < HotCell::Operation
  operation "images.transform"    # the same routing name

  # Ceilings for one request enforced by rlimits and the supervisor's clock,
  # clamped to the cell's own limits.
  limits deadline: 30.seconds, memory: 1280.megabytes, file_size: 48.megabytes

  before_fork        { require "my_image_processor" }       # once, in the supervisor
  before_worker_boot { MyImageProcessor.concurrency_set 4 } # in forked worker, before it serves a request

  # The descriptors the caller passed, and the payload as keyword arguments. A missing or undeclared
  # key raises, so the signature is the schema. Declare **payload instead to take the Hash whole.
  def perform(inputs, outputs, format:, operations: {})
    source, = inputs
    destination, = outputs

    # fd_path reads the caller's file in place, with no copy onto scratch, so an input of any size
    # costs nothing against file_size. Reach for source.path only when a tool needs a distinct on-disk
    # copy; that stages the bytes, and the kernel charges the write.
    MyImageProcessor.source(source.fd_path)
                    .apply(format:, operations)
                    .write_to(destination.fd_path)

    # The result: one JSON object, which the caller receives as perform_in_hotcell's return value (in
    # addition to the destination file descriptor)
    { format: format, bytes: File.size(destination.path) }
  end
end
```

`before_fork` runs once in the supervisor and must never evaluate an image; `before_worker_boot`
runs in the worker and is where a library gets sized. `unreadable` names the library exceptions that
mean "this input cannot be decoded", a permanent verdict. An operation that shells out calls
`run_tool "mutool", "draw", ...` and gets the exit status and bounded output back; the tool sees
only the environment the operation wrote.

A subclass inherits the `hotcell` name but not the `operation` name. The operation name is the wire
name, so to avoid answering to the same name as its parent, it derives its own from its class path
unless one is declared.

### Changing a shipped operation's limits

An operation's `limits` is a class-level declaration that accumulates: naming one limit changes that one
and keeps the rest. So an operator can give a shipped operation a different budget without editing the
gem, by redeclaring the one number after the operation loads:

```ruby
# hotcell/operations/zz_limits.rb
require "active_storage/hot_cell/server/transformers/image/vips"

ActiveStorage::HotCell::Server::Transformers::Image::Vips.limits file_size: 128 * 1024**2
```

The transformer's `deadline`, `memory` and `open_files` are unchanged. Naming a limit to `nil` withdraws
it, which hands that one back to the cell's number.

Three things about that file.

**Require the operation first.** The class has to exist before it can be redeclared. `config.rb` loads
before any operations file, and operations load in sorted order, so a redeclaration that relies on load
order alone belongs in an operations file that sorts last — hence the `zz_` prefix. The `require` at the
top removes that dependency: with it, the same two lines work from any operations file, or from
`config.rb`. Prefer an operations file anyway, so every declaration about operations lives in one place.

**A subclass works the same way, and copies at the moment it declares.** One that declares
`limits deadline: 5` takes every other value from its parent, so a narrowing subclass writes the number it
narrows and nothing else. It takes them once: `limits` resolves to the first ancestor that declared any,
and once a class has stored its own it stops looking up. So redeclaring the parent afterwards does not
reach a child that has already declared — redeclare the child too. A subclass that never declares follows
its parent live.

**The cell's numbers are still the ceiling.** A redeclaration can only ask; the cell clamps it the way it
clamps the original, so the effective value is the smaller of the two. To receive 128MB the cell's own
`file_size` has to allow at least 128MB. A cell at 64MB gives that redeclaration 64MB — a change, but not
the one asked for.
