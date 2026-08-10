# HotCell

A build specification. Nothing described here exists yet, and it is meant to be built from scratch.

Section 8 collects facts established by direct testing rather than by reasoning. They are the parts
most likely to be got wrong and the cheapest to confirm independently, so confirm them rather than
taking this document's word for it.

References to Fizzy, Basecamp 4, haystack#8538, haystack#8546, and
[`basecamp/thimble`](https://github.com/basecamp/thimble) are evidence for requirements, not code to read
or depend on. Every requirement they support is stated here in full.

thimble deserves a note of its own, because it is the same problem solved a different way and it is
further along: a conversion service holding no secrets, deployed as a Kamal accessory, reached over HTTP on
the shared network. Where this document cites a measurement from it — LibreOffice profiles, hardening
flags, queueing, error classification — that measurement was taken on a built image in production use, and
is worth more than anything derived here from first principles. Read it before building this, and read it
critically: it carries a Sentry DSN and mounts a shared exchange volume, so some of its controls exist to
protect things a hotcell deliberately does not have.

## 1. What this is

HotCell moves untrusted work out of a privileged application process into an unprivileged,
resource-capped, network-less sibling container. The application reaches in through a narrow
interface. The work never reaches out.

A hot cell is a shielded chamber for handling highly radioactive material. The operator stays outside
and manipulates the contents remotely, and nothing leaves except by controlled transfer. The
vocabulary follows: **hot** is untrusted, **cold** is trusted, and material is **posted in** and
**posted out**. Everything else uses the ordinary word. An operation declares its **limits**, and a
cell has a **concurrency limit**.

### The problem

Firejail and similar sandboxes do not work inside a container, because containers and sandboxing use
the same kernel features. An application deployed in a container therefore runs media libraries
unconfined. A vulnerability in libvips, `soffice`, `mutool`, `ffmpeg`, or ImageMagick, reached through
an uploaded file, executes with the application's secrets, its database credentials, its code, and its
network.

Basecamp 4 shows the shape of it. `lib/sandboxed_script.rb` sets
`SANDBOXED = !(Rails.env.local? || BC3.deployment.kamal?)`, so under Kamal its sandbox is disabled and
those tools run unconfined against user uploads.

An independent investigation reached the same conclusion:
[Converter sandbox — the actual closing fix](https://app.basecamp.com/2914079/buckets/48394871/card_tables/cards/10170494972).
Two findings from it shape this design. Scrubbing a tool's environment does not help, because a
file-read primitive can retarget `/proc/<parent>/environ` at a same-UID process, which was verified
leaking `RAILS_MASTER_KEY` on the production image *through the scrubbed invocation*. And moving
secrets out of the environment does not help either, because the same primitive reads arbitrary files,
including `config/master.key`. That card weighs two remedies: a bubblewrap or nsjail wrapper inside the
application image, or a separate conversion service holding no secrets. HotCell is the second.

Choosing the second also sidesteps the risk the card attaches to the first, which is that an in-image
wrapper has to be verified to work under Kamal's container. That verification is exactly what firejail
failed, and why BC4's sandbox is dead.

### Threat model

Assume arbitrary code execution inside a cell, or merely an arbitrary file read, reached through a
malicious input file. The design must make that outcome cheap.

In scope: reading application code or secrets, reaching the database, reaching the network, reading
another request's memory or environment, consuming the host's CPU or disk, escalating through a path
the application later opens, and reaching a different cell's toolchain.

Out of scope: a kernel container escape, a malicious operation implementation, and denial of service
against a cell.

Out of scope means the design does not promise to stop it, not that it is harmless. A malicious
operation — most plausibly a supply-chain compromise in a gem an operation depends on — is in fact
contained by everything here, because an operation runs in the same cell under the same limits as the
library it calls. It is excluded because it is not what this design is *for*, and because treating it
as in scope would drag operation review and dependency policy into a document about a transport.

The card frames the requirement as "a PID and mount namespace exposing only the input and output, no
`/proc`, no application filesystem." HotCell meets the namespace requirement by being a separate
container, and **exceeds the input/output part**: descriptors mean there is no path in the cell to
expose or to traverse, rather than a narrowed set of bind mounts. The `/proc` requirement is treated
separately under "Worker isolation", because it is the one part that a container boundary does not give
us for free.

## 2. Architecture

### Gems

Five. What matters is which code **loads and runs** in a cell, not which files are present.

| Gem | Runs in | Contains |
| --- | --- | --- |
| `hotcell-core` | both | Wire protocol, `SCM_RIGHTS` marshalling, `HotCell::Input` and `Output`, payload validation, error taxonomy. No I/O. No media libraries. |
| `hotcell-client` | app | `HotCell::Client`, server registration, routing, instrumentation. Depends on core and `activesupport`. |
| `hotcell-server` | cell | Supervisor, worker, `HotCell::Operation`, container image, Kamal recipe. Depends on core only; deliberately not `activesupport`. |
| `activestorage-hotcell-client` | app | The transformer, analyzer, and previewer you configure Rails with. Depends on `hotcell-client` and `activestorage`. |
| `activestorage-hotcell-server` | cell | Operation implementations. Depends on `hotcell-server` and `ruby-vips`. **Must not load `activestorage`.** |

Nothing is shared between a client and its operation. They are two classes in two gems, never both
loaded, coupled only by an operation name on the wire.

**All five live in one repository for now.** Writing the Active Storage gems twice required changing
`hotcell-server` first, which is what a coupled seam feels like; splitting a system before its seams are stable
costs more than merging it later, and while nothing is published splitting is a directory move. The tasks and
the CI jobs keep the two halves apart, because the three hotcell gems claim to be testable with no tool and
no container installed and a single job that installed libvips would stop that claim from ever being checked.

**"Never both loaded" is not enough on its own, so the namespaces enforce it.** A cell is forked from a process
that may well have loaded the client, and the child then meets those constants before defining its own — a
superclass mismatch while the cell boots. Everything the application side defines lives under
`ActiveStorage::HotCell::Client` and everything the cell side defines under `ActiveStorage::HotCell::Server`, so
no future class in either gem can collide with one in the other.

Paths use `hot_cell/`, so the default inflection yields `HotCell` without registering one. The
constant is `HotCell` rather than `Hotcell` because an unrelated `hotcell` gem defines the latter.

**Ruby, and the cost of choosing it.** A cell image must carry a Ruby runtime, bundler, and every gem in
the loaded graph, all inside the blast radius. The closest comparable design chose a static binary with
no interpreter in the runtime image at all, and left no reasoning to rebut, so the case for Ruby has to be
made rather than assumed: operations are the extension point, applications that will write them are Ruby
applications, and an operation that cannot be written in the language of the code it replaces will not be
written. The price is a larger surface, so treat the table above as a budget and not just an inventory.
`hotcell-server` depending on `activesupport` would be the first breach of it.

### Ownership and versioning

Five gems and a base image, serving more than one product, on an accessory that a deploy does not update.
Two things follow that a design document is the right place to fix.

**Ownership.** Say who owns the gems and the base image, and give every consuming team write access. The
duty that has to be live rather than nominal is toolchain CVE response: when libvips, `mutool`,
`ffmpeg`, or ImageMagick has one, somebody cuts a patch release of the base image and opens the bump in
every consumer. Nothing else in this document works if that duty is unassigned. The base image repository
should deploy nothing itself, so that paging follows each application's own accessory.

**Versioning.** Version the gems against **the wire contract**, not against the image. A cell is rebooted
independently of the app that calls it, so client and server versions will differ in normal operation, and
the rule needs to be stated rather than discovered: the client may lag the server, and the contract
version is what has to match. This is the same skew that makes the `protocol` error code transient rather
than a bug.

**Ship the test double from the server gem.** Every consumer otherwise writes its own stub cell, and they
drift. One double, shipped where the contract lives.

### Extension

**An application extends an existing hotcell rather than building its own.** This is the primary way
HotCell is meant to be used, not a fallback. Three moving parts, none of which touch the base gems:

1. **Derive the image.** `FROM` a published hotcell image, install whatever system libraries and gems
   the new operations need, and copy the operation classes into the load path. See section 4.
2. **Add operations.** Subclass `HotCell::Operation`, declare `limits`, `before_fork`, and
   `before_worker_boot`, and implement `perform`. The supervisor reads in whatever it finds.
3. **Add thin client classes.** Subclass `HotCell::Client` and name the cell with `hotcell`. These
   carry no logic beyond that, because `perform_in_hotcell` is inherited and the signature is uniform.

The extension point is `HotCell::Operation` and `HotCell::Client`, not the Active Storage gems, so an
operation does not need Active Storage underneath it. BC4 is the proof: alongside its Active Storage
work it needs avatar rendering, which composites an application asset over a blob, initials avatars,
which render text with no input file at all, and zip export, none of which involve a blob-shaped
operation.

An operation is also the answer to work that does not decompose over the wire. A pipeline whose
intermediate is a live library object rather than bytes — BC4's avatar renderer produces a `Vips::Image`
and feeds it to a second pipeline — belongs inside one operation, where the intermediate never has to be
serialized or cross the boundary. Extensibility is what makes that a non-problem rather than a
limitation of the protocol.

Whether to add operations to an existing cell or to run a new one is a blast-radius decision. Anything
sharing a cell shares its process, its image, and its toolchain, so an application that wants its
libraries kept apart from another's should register a second cell rather than extend the first.

**The closest comparable design refuses this extensibility on purpose, and the reason does not apply
here.** [`basecamp/thimble`](https://github.com/basecamp/thimble) exposes a closed enum of conversions
and builds every tool argv server-side, because it holds no secret and therefore cannot verify the
signed transformations hash an app embeds in a variant URL — so an open "apply these operations"
contract would be a network-reachable ImageMagick RPC drivable by anything that can reach the accessory.
That is a consequence of an unauthenticated HTTP listener on a shared network. HotCell's transport is an
`AF_UNIX` socket under `network: none`, in a directory mounted into exactly two containers, so "anything
that can reach it" is already "the application". The argument is worth stating because a reader who
knows thimble will otherwise read `perform(inputs, outputs, payload)` as the mistake thimble named.

What survives of that concern is the value allowlist, and it survives in full: see "Validation belongs
to the operation". The transformations reaching an operation are **not** drawn from anything the
application currently declares — they are whatever a signed URL says, of any age — so the operation's
own allowlist is the only one there is.

**This is the one place application code deliberately runs inside a cell.** The point is not "no application
code," it is that the code which runs there has no application credentials, no database, no network, and no
application configuration. An operation receives descriptors and a payload, and nothing else.

What holds that line is the container, not a check on what the container contains. Invariant 2 is about what is
in the image and the environment; nothing inspects the loaded gem graph, and an earlier draft's boot self-check
for invariant 1 has been withdrawn. An operation is free to require whatever it needs.

### Cells

A deployment runs one or more cells, each an independent process on its own Unix socket, with its own
consist of operations, its own concurrency limit, its own deadline, and its own image. A cell does not
know it has siblings; multiplicity is entirely a cold-side and deployment concern.

This is how toolchains stay apart. A vips-only cell carries neither ffmpeg nor mutool, so code
execution in one toolchain does not land beside another's binaries.

**A cell is also the unit of scheduling fairness, and the only one.** Work inside a cell competes for
one concurrency limit, first come first served, with no per-operation priority. So a video preview
measured in minutes and an avatar thumbnail measured in milliseconds must not share a cell: the video
work will occupy the limit and the thumbnails will queue behind it. Separate them by running separate
cells, each sized and time-limited for the work it does. Per-operation scheduling inside a cell is not
forbidden, just not worth building yet: it needs the supervisor to learn what it is dispatching, and one
limit per cell plus a second cell where the work differs covers the cases we have.

**A second cell is not free, and the cost should be named rather than assumed away.** It is another
image to build and publish, another socket, another volume mounted into the app, another accessory to
boot on every host, and another reboot in every deploy procedure. thimble reached the opposite
conclusion for the same problem — it runs LibreOffice and mutool in one accessory separated by two
internal pools, precisely so a fifty-second Office job cannot stall a millisecond PDF render — and that
is a reasonable trade when the two tools are maintained together. HotCell pays the container cost
instead and gets a smaller blast radius for it, because a `soffice` compromise in a shared accessory
still lands beside mutool. Take the second cell when the toolchains differ; do not take it to separate
two operations over the same library.

`soffice` is the clearest case for a cell of its own. Fizzy's image installs `libreoffice-writer`,
`libreoffice-impress`, and `libreoffice-calc` beside `mupdf-tools` and `ffmpeg`, and LibreOffice is a
far larger surface than the other three combined. It also wants a writable home directory and a much
longer deadline than an image transform, so it fits badly in a shared cell on every axis. It is also
the tool with a working prototype already: see haystack#8538.

### Process model

```
cold side (privileged)                     hot side (unprivileged), one per cell
──────────────────────                     ─────────────────────────────────────
app process                                supervisor                       pid 1
  TransformImage < HotCell::Client            reads in operations, runs before_fork
    wraps IOs as Input/Output                never evaluates image data
    validates the payload                    accepts, queues, dispatches with a slot
    connects to its cell's socket            times the deadline, kills, reaps, cleans up
    sendmsg: JSON + N fds  ─────────────►
                                           worker            serves `max_requests_per_worker` requests
                                             reads the request, resolves the operation
                                             runs before_worker_boot
                                             applies limits
                                             runs perform
                                               an input copies itself to scratch when asked for a path
                                             posts outputs, flushes
                       ◄─────────────────     one JSON line, then exits or waits
```

**The supervisor must never evaluate image data.** This is a hard requirement and the reason is
mechanical, not defensive: libvips starts its thread pool on the first evaluation and that pool does not
survive `fork`, so a supervisor that has touched an image forks workers that deadlock forever. See
"Established by experiment", item 1. It is also why `before_fork` may require and configure but must not
evaluate.

Reading the request line is a different thing and is fine. It is a control message from the trusted side,
generated by our own client, on a bounded buffer. The supervisor keeps its work small because it is pid 1
and simple is easier to keep correct there, not because parsing would be dangerous.

**The supervisor accepts and dispatches; workers never call `accept`.** It hands an accepted connection to
a worker by passing the connection descriptor over the worker control socket. The client's own
`SCM_RIGHTS` descriptors stay queued on that connection until someone calls `recvmsg`, and the supervisor
never does — so the worker's `recvmsg` is what installs them. Same primitive as everything else here, and
the supervisor stays out of the request.

Dispatching rather than letting workers accept is what makes the rest work. The supervisor needs to own
the accept anyway, for the queue, for `queued_ms`, and to answer `capacity`. It also means **the supervisor
knows when every worker started its current request**, which is what the deadline needs.

**The deadline is always enforced by the supervisor, with a signal.** Never by the worker on itself.

The supervisor never reads a request, so it cannot know that an operation declared less than the cell's
maximum. The worker tells it, on the control socket, before it touches an untrusted byte — and the supervisor
**clamps what it is told**, because the worker is the one process here running untrusted code and may only ever
narrow. That is invariant 6, enforced on the side that owns it.
 A
Ruby-level timer cannot interrupt a thread pinned in a C extension: `Timeout` works by raising in the
target thread, and the exception is only delivered at an interrupt checkpoint, which a thread inside
`vips_resize` with the GVL released will not reach until it returns. So self-enforcement fails in exactly
the case a deadline exists for. A worker may additionally bound its own `exec`'d tool child, which is
cheaper and useful, but that is a nicety on top and not the control.

### Deployment

One Kamal accessory per cell. Accessories, not app roles, because Kamal hard-codes `--network kamal`
for app roles and only an accessory can set `network: none`. An accessory can target
`roles: [web, jobs]` to land on the same hosts as the app.

Cell flags, all expressible as Kamal accessory `options`, which are passed through to `docker run`:

```yaml
options:
  network: none
  read-only: true
  tmpfs: /tmp:rw,nosuid,nodev,noexec,size=512m
  memory: 2g
  memory-swap: 2g
  cpus: 2
  pids-cause: 512
  cap-drop: ALL
  security-opt: no-new-privileges:true
  user: 10001:10001
  ulimit: stack=2097152:2097152
```

`ulimit stack` is here rather than in an operation's `limits` because `RLIMIT_STACK` cannot be changed after
`exec` — glibc snapshots it at process init, and a `Process.setrlimit` call in the worker changes the
reported value and nothing else. It is worth roughly 140MB of `RLIMIT_DATA` headroom per worker at
concurrency 4, because every thread the libvips pool starts reserves a stack. See section 4.

`noexec` on the tmpfs is the one that is easy to omit and worth the most, since the scratch directory is
exactly where a dropped payload would land. `memory-swap` equal to `memory` stops the memory cap leaking
into swap. The uid is high and outside any host user range, created `--no-create-home` with `nologin`.

Host precondition: `kernel.yama.ptrace_scope >= 1`. See "Worker isolation".

**Sockets live one per directory, and the directories are not shared between cells.** A cell named
`archiver` gets `HotCell.root/archiver/`, holding both its sockets, and that directory is a volume mounted into the
app and into that cell only. If several cells shared one directory, a compromised cell could submit
work to another cell's toolchain, which defeats the reason for having more than one.

**A cell listens on two sockets, and the split is deliberate: one data path, one side-band control
channel.** `work.sock` carries conversions. `control.sock`, beside it, carries the built-in operations in
"The control channel".

Keeping control off the data path buys three things. Control answers when the cell is saturated, where a
health check or a metrics scrape sharing the work queue would fail under load and report the same thing as
an outage. Each side gets its own concurrency allowance and its own deadline, which are not the same
numbers — a scrape is milliseconds, a conversion is seconds. And the socket a connection arrived on is
itself the discriminator, so routing costs nothing and cannot be confused by a payload.

It is also the place any later control message belongs — drain before a reboot, reload the consist, quiesce
a slot — none of which is in scope now, and all of which would otherwise want inventing a channel under
time pressure.

**The socket's file mode is the access control on connecting, and the two sides do not share a uid.**
A Unix socket is a filesystem object, and `connect` needs write permission on it. The cell runs as
10001 and the app runs as whatever its own image says, so a socket created 0600 by the cell is
unreachable by the app and the failure is a bare `EACCES` at the first variant. Create it `0666` and
rely on the mount topology, which is what actually contains this: the directory is a volume mounted
into exactly two containers, so "anyone who can see this socket" is already "the app and the cell." A
shared supplementary gid with mode `0660` is tighter and needs the two images to agree on a number
forever, which is a coordination cost for no threat this design is trying to stop. Take the `0666` and
write down why.

Accessories are not updated by a deploy and need an explicit `accessory reboot`.

Local development runs a compose service per cell with the same flags, driven by rake tasks, because a
bind mount source must exist before the container starts.

### Invariants

These are the design properties the whole thing exists to hold. They are not a test plan. Most are
verifiable by reading the code, and a test that restates what an obvious ten-line method plainly does
buys nothing but maintenance.

Test the ones where inspection is not enough — where the behaviour is the kernel's rather than ours, where
it is silent when broken, or where a plausible refactor would quietly remove it. Section 10 says which,
and why.

Invariant 2 is the awkward one. "A cell holds no application credentials" is a negative over a whole
filesystem and cannot be asserted directly. It stays on the list anyway, because it is the property the
whole design exists to hold. What the tests can reach is narrower: the built image contains no application
source tree, and `docker/smoke` boots the hardened container and checks its flags directly.

A cell could go further and enforce it, by reading an allowlist of environment variable names and refusing
to boot on anything outside it. That is deferred, not rejected. It is a boot check that can be added at any
time without touching anything else here, and it addresses an operator mistake rather than the threat this
design is about.

1. ~~No application framework loads in a cell.~~ **Withdrawn.** Nothing enforces this and nothing should. The
   whole design is that the container provides the guarantee structurally, so policing what code runs inside it
   both duplicates a control that already holds and implies it does not. Under `network: none` a loaded
   `ActiveRecord` cannot reach a database, and untouched pages are not copied, so the copy-on-write argument for
   warning about it was not real either. Keeping a cell's gem graph small is still worth doing — a smaller graph
   is a smaller thing to audit — but that is a budget, not a rule about what an operation may require.
2. A cell holds no application credentials, in its environment **or on its filesystem**.
3. The supervisor never evaluates image data, and a worker forked from it produces correct output.
4. Descriptor access modes are one-way: an input cannot be written, an output cannot be read.
5. No filesystem path chosen by a hot side is ever opened by the cold side.
6. An operation cannot exceed its cell's limits, whatever it declares.
7. A cell cannot reach another cell's socket.
8. A worker cannot read another **request's** memory. Conditional on two things: `kernel.yama.ptrace_scope
   >= 1`, a host setting no container flag can supply, and `max_requests_per_worker: 1`. Not files — see "Worker isolation".
9. A tool subprocess sees only the environment its operation wrote for it.

### Worker isolation

Workers in a cell are siblings under one UID in one PID namespace, so another worker's `/proc` entries
are same-UID reads. Measured, not assumed (items 7 and 8 in "Established by experiment"):

| Target | At `ptrace_scope = 1` | Why |
| --- | --- | --- |
| `/proc/<sibling>/mem` | `EACCES` | Needs `PTRACE_MODE_ATTACH`, which Yama restricts to descendants. |
| `/proc/<sibling>/environ` | **Readable** | Needs only `PTRACE_MODE_READ`, which Yama does not restrict. |
| `/proc/<sibling>/fd/N` | **Readable** | Same `PTRACE_MODE_READ`. So are the scratch files themselves, by directory listing. |

So invariant 8 has three parts and they have different answers. Only the first is about `ptrace_scope`.

**Request memory** is protected by `kernel.yama.ptrace_scope >= 1`. That is a host sysctl a container
cannot set, so it is a deployment precondition. At `ptrace_scope = 0` the guarantee is gone, and the
cell should therefore **refuse to boot** rather than log a warning and serve anyway. A host sysctl is
invisible to the image, it silently voids the guarantee, and a warning in a log is how a dead control stays
dead. This is the one boot check worth having now.

**Above `max_requests_per_worker: 1` this invariant is about workers, not requests.** A worker serving several requests in
turn holds each of them in the same address space, so an input that achieves code execution can read and
tamper with every later request that worker handles — no race to win, and covering requests that were never
concurrent with it. That is a deliberate setting with a measured payoff, described under "Worker max_requests_per_worker", and
it is the only place in this design where the isolation between two requests is a configuration value.

**Files are not isolated between concurrent workers, and cannot be.** Every worker runs as the same uid
in one mount namespace, so a worker that reads another worker's scratch directory — by listing it, or
through `/proc/<sibling>/fd/N` — gets that request's input and output bytes. Unlinking the scratch file
does not close it, because the descriptor is still reachable through the sibling's `/proc`. The two
fixes that would work need `CAP_SETUID` for a per-worker uid or `CAP_SYS_ADMIN` for a per-request mount
namespace, and `cap-drop ALL` removes both. This is the same shape as the environment: a real residual,
stated rather than papered over.

What bounds it is the size of the window and the value of the contents. Only requests actually in flight
have bytes inside a cell, a cell holds no credentials, and a cell carries one toolchain. So the exposure
is "the other conversions happening right now in this cell", which is why per-toolchain cells and a
sober `concurrency` are containment decisions and not just scheduling ones.

This corrects an overclaim worth being explicit about, because it is easy to make: fork-per-request buys
**memory** isolation, not file isolation. Appendix A's argument for descriptors is about the boundary
between the application and the cell, and it does not extend to workers inside one cell.

**Environment** is not protected by `ptrace_scope` at all, and cannot be fixed inside the worker. A
forked process's `/proc/self/environ` is the exec-time environment of the process it was forked from,
so a worker calling `ENV.delete` changes nothing about what a sibling reads. Two controls replace it.
Invariant 2 keeps anything worth stealing out of a cell's environment in the first place. And invariant
9 requires tools to be spawned with `unsetenv_others: true` and an explicitly written environment,
because a tool is `exec`ed and therefore does get a fresh `/proc/<pid>/environ` — the one thing in
this picture that is actually under our control.

`hidepid=2` on `/proc` would remove the sysctl dependency by hiding sibling processes entirely, and it
is not available: Docker rejects Podman's `--security-opt proc-opts=`, and remounting `/proc` inside the
container needs `CAP_SYS_ADMIN`, which `cap-drop ALL` removes. Revisit only if the runtime changes.

This is the third `/proc` surprise in this design, after `/proc/self/fd/N` laundering a read-only
descriptor and the environ retargeting that motivated the whole project. `/proc` is where these
assumptions go to die, and it deserves the attention.

## 3. `hotcell-core`

### Transport

`AF_UNIX` stream socket. One request per connection. The cold side connects, sends one request, reads
one response line, and closes. The hot side never initiates.

**`SOCK_STREAM`, not `SOCK_SEQPACKET`, and the receiver must handle a short read.** `SOCK_SEQPACKET`
would give real message boundaries and remove the framing problem outright, and it is the better fit
on paper. It is not available: Darwin has no `AF_UNIX`/`SOCK_SEQPACKET`, and section 9 requires a cell
to run natively on macOS. So we take `SOCK_STREAM` and pay for it once, in the receiver: a stream
socket does not promise that one `sendmsg` arrives as one `recvmsg`, and the ancillary data rides on
whichever bytes land first. Read to the newline in a loop, and capture the descriptors from the first
`recvmsg` that carries them rather than assuming they arrive with the whole line. Write this down where
the receiver lives, because it works by accident under every test small enough not to fragment.

**Local only, by design.** `SCM_RIGHTS` works only over `AF_UNIX` and cannot cross a network. A
network listener would also replace `network: none`, the strongest containment property here, with a
firewall rule. A network transport is not a future extension of this design; it is a different design
with a weaker guarantee.

[haystack#8538](https://github.com/basecamp/haystack/pull/8538) is the worked example of the other
choice. It puts its conversion service on the shared `kamal` network over HTTP, which is the right call
for a single service shipping now: no descriptor machinery, and it works across hosts. Its own limitations
section then names the price, that the service can still reach the internal network, so a document
that persuades LibreOffice to fetch a URL is an SSRF pivot, and closing it would need an `--internal`
network plus a coordinated change to every app container. Under `network: none` that pivot does not
exist. The cost we pay instead is that a cell must be on the same host as its caller.

### The uniform signature

Every operation, on both sides, takes the same three arguments. There is no per-operation argument
schema, no generated code, and no introspection.

```ruby
perform_in_hotcell(inputs, outputs, payload)   # cold side
perform(inputs, outputs, payload)              # hot side
```

`inputs` and `outputs` are arrays of `HotCell::Input` and `HotCell::Output`. `payload` is a Hash. An
operation destructures what it expects at the top of `perform`:

```ruby
def perform(inputs, outputs, payload)
  image, overlay = inputs
  result, = outputs
end
```

An operation that receives the wrong count fails inside `perform` and reports `failed`. That is
acceptable: the blast radius of a miscounted argument is one worker with no network, and it buys back
an entire declaration layer.

### Request

One line of UTF-8 JSON terminated by `\n`, at most 8192 bytes, sent with a single `sendmsg` carrying
one `SCM_RIGHTS` message.

```json
{"v":1,"op":"active_storage.transform_image","inputs":1,"outputs":1,"payload":{"format":"png","operations":{"resize_to_limit":[800,600]}}}
```

| Field | Rule |
| --- | --- |
| `v` | Protocol version. Must equal the cell's. Checked, never negotiated. |
| `op` | Namespaced operation name. The namespace prevents collisions between operation sets. |
| `inputs` | Count of leading descriptors that are inputs. |
| `outputs` | Count of trailing descriptors that are outputs. |
| `payload` | JSON object. |

The cell rejects a request whose received descriptor count is not `inputs + outputs`.

Descriptors must be regular files. Posting out is one streaming write, so a pipe as an output can
deadlock against a cold side that is not draining it.

### `HotCell::Input` and `HotCell::Output`

These verify, they do not merely tag. `Input` checks the descriptor's flags with `fcntl(F_GETFL)` and
raises unless it is read-only. `Output` raises unless it is write-only.

**The cell repeats the check on receipt and refuses the request otherwise.** A descriptor's access mode
is fixed at `open` and cannot be narrowed afterward, so a cell cannot fix a mistake, only decline it.
This keeps a buggy cold side from silently handing a cell write access to an application file, which
would end invariant 4.

### Payload rules

Payload **values** must be JSON-native: strings, numbers, booleans, null, arrays, and objects. Payload
**keys** may be Strings or Symbols, since both serialize to JSON strings and both arrive symbolized.
`{ format: "png" }` is the natural way to write a payload and must not be rejected.

`to_json` is not a check. It serializes a Symbol value to a String, a Time to a String, and an
arbitrary object through its own `to_json`, all silently and none faithfully. So **validate values for
JSON-native types first, then serialize**, and raise on anything else the way
`ActiveJob::SerializationError` does.

Parsing on the hot side: `JSON.parse` only. Never `JSON.load` and never `create_additions: true`,
which instantiate arbitrary classes from a `json_class` key. Pass an explicit low `max_nesting` and
`allow_nan: false`.

**Keys are deep-symbolized on arrival.** Every object key becomes a Symbol, at every depth, before
`perform` sees the payload. This is part of the wire contract rather than an operation's concern, so an
operation never has to know whether to reach for `payload[:format]` or `payload["format"]`, and a
nested hash can be splatted straight into a media library's keyword arguments. `result` works the same
way in the other direction: an operation returns symbol keys, they serialize as strings, and the client
symbolizes them on receipt.

Only keys are symbolized. Values are not, and a Symbol value would not survive the round trip anyway,
which the JSON-native rule above already forbids. `max_nesting` is what bounds the recursion, since
deep symbolization walks the whole structure.

Symbolization is not a security control and must not be gated on validation. Dynamic symbols have been
garbage collected since Ruby 2.2, and the payload is capped at 8KB regardless. The control that matters
is the allowlist on dispatch names, and it applies to `public_send` whether the name arrived as a String
or a Symbol.

### Response

One line of JSON. Outputs are written and flushed before success is reported, so the cold side may read
as soon as it sees `ok`.

```json
{"v":1,"ok":true,"result":{"width":800,"height":600,"bytes":65345,"content_type":"image/png"},"timing":{"queued_ms":0,"perform_ms":47}}
{"v":1,"ok":false,"error":{"code":"unreadable","class":"Vips::Error","message":"…"},"timing":{"queued_ms":0,"perform_ms":5}}
```

`result` is whatever `perform` returns, and is subject to the same JSON-native rules. It is required,
even when empty.

`timing` is present on every response, success or failure. `queued_ms` is how long the supervisor held
the connection before forking, and `perform_ms` is the worker's own measurement of `perform`. The cold
side already knows the wall clock for the whole call, so with these two it can separate three things
that need separate metrics: the work got more expensive, the cell got saturated, or the transport got
slow. See "Instrumentation".

**`timing` is also the cell's tracing channel, so break `perform_ms` down.** A cell cannot reach a trace
collector, so anything it knows about its own internals has to travel back in the response or not at all:

```json
"timing":{"queued_ms":0,"convert_ms":44,"writeback_ms":2,"perform_ms":47}
```

Those phases sum to roughly `perform_ms` and cost nothing to collect. The client turns them into child spans
in the application's own tracer, so a trace shows where time went inside the cell without the cell speaking
any tracing protocol. An operation may add its own keys; the client should treat the map as open.

The same logic applies to a backtrace. If a cell-side backtrace is wanted for error grouping, it travels on
the wire under `error`, capped and scrubbed like `error.message` — it comes out of a process that has just
parsed a hostile file, and the rules in "`error.message` is untrusted" apply to it in full.

On `killed` the worker is dead and cannot report anything, so the supervisor fills `perform_ms` in with
the time from fork to reap. That is an upper bound on `perform` rather than a measurement of it, and it
is worth having, because "killed at 30s" and "killed at 0.2s" are different bugs.

Several callers need it. Analysis returns metadata and no bytes. `ffprobe` returns its JSON. A
transform returns metadata about its own output: BC4's `Blob::Preview::Thumbnailer` reads the output
header for width and page height, and `Person::Avatar::Image::Renderer` returns rendered bytes together
with their metadata. `result` also replaces the one thing a wire protocol cannot carry, BC4's
`custom { |vips| vips.tap { @width, @height = vips.width, vips.height } }`, which captures state back
into the caller.

### The error taxonomy, and the one distinction that matters

Every error carries a code and a **`permanent`** flag.

```json
{"v":1,"ok":false,"error":{"code":"unreadable","permanent":true,"class":"Vips::Error","message":"…"},"timing":{"queued_ms":0,"perform_ms":5}}
{"v":1,"ok":false,"error":{"code":"killed","permanent":true,"limit":"cpu"},"timing":{"queued_ms":0,"perform_ms":30011}}
{"v":1,"ok":false,"error":{"code":"killed","permanent":false,"limit":"deadline"},"timing":{"queued_ms":0,"perform_ms":60002}}
```

**`permanent` means the same request will fail the same way until the input or the code changes — not
until the load or the deployment changes.** So a permanent error may be recorded against the blob and
served from a cache. A non-permanent error must be retried and **must never be written down**.

The flag is on the wire and set by the side that knows, rather than derived by each caller from the
code. This is not tidiness. A caller cannot tell from `killed` alone whether a worker burned thirty CPU
seconds on a decompression bomb or merely sat behind a queue past a sixty-second deadline, and those
demand opposite responses. It also makes a new code safe to add later: an old client will not recognise
it but will still handle its disposition correctly.

| Code | Written by | `permanent` | Meaning |
| --- | --- | --- | --- |
| `unreadable` | worker | true | The input could not be decoded. |
| `failed` | worker | true | The operation raised for some other reason. |
| `invalid` | worker | true | Malformed request, or descriptors that failed their access-mode check. |
| `unsupported` | worker | **false** | This cell does not carry that operation. |
| `protocol` | worker | **false** | Version mismatch. |
| `killed` | supervisor | see `limit` | The worker died. `limit` is one of `fsize`, `memory`, `deadline`, `signal`, `crashed`. |
| `capacity` | supervisor | false | The queue is full. |
| `unavailable` | **client** | false | No connection, or the connection closed with no response. |
| `timeout` | **client** | false | The client's own deadline fired. |

Four of these need their reasons stated, because getting any of them wrong is a production incident.

**`killed` splits on `limit`, and only some of its values are permanent.** `fsize` and `memory` are
properties of the input: the same bytes will do it again on an idle cell, so they are permanent. `deadline`
is a property of the load as much as of the input — a worker can exhaust wall-clock time while barely
touching the CPU, because it was waiting. Treating a deadline breach as permanent means a slow afternoon
permanently condemns whatever was uploaded during it.

**`memory` belongs on `killed`, not in `failed`.** An `RLIMIT_DATA` failure is a catchable allocation
error rather than a signal, so it is tempting to let the operation report it as an ordinary failure. It
is the decompression-bomb case — the exact thing the limit exists for — and it belongs with the other
resource verdicts so a caller can act on it without parsing a message.

**`protocol` is split out of `unsupported` because the two heal differently, and both are transient.**
During a rolling deploy where the app moves before the cell, every version mismatches until the accessory is
rebooted. Alarm on duration, not on first occurrence.

**`unsupported` was permanent in an earlier draft, on the reasoning that an unknown operation is a caller bug
that never heals. That is true of a typo and false of the case that actually happens.** An accessory is not
updated by a deploy, so an application that ships a client for a new operation before anybody reboots the cell
gets `unsupported` at one hundred percent for as long as that takes. The two mistakes are not symmetrical:
retrying a typo costs some work and shows up in the `unsupported` rate and in the client's boot-time warning,
where recording a deploy window as permanent condemns every blob uploaded during it and needs a hand-written
backfill to undo.

**`crashed` is a worker that died mid-request without a signal**, which a misconfigured cell does on every
request. It is the cell's fault rather than the input's, so it is not permanent.

**`unavailable` and `timeout` are synthesized by the client and belong to the same taxonomy**, even
though no cell wrote them. They are the most likely failures in production — a cell restarting, an
accessory not yet booted, a socket that does not exist — and they produce no wire response at all. If
they sit outside the taxonomy then the `code` on the instrumentation event is blank for exactly the
outage you most want to see. Note that a closed connection with no response means the *supervisor*
died, since a live supervisor answers `killed`; that is the whole reason it holds the connection.

`unreadable` is common rather than exceptional, and is why `error` is structured rather than a string.
It covers truncated uploads, formats the build was not compiled with, and formats deliberately refused
by `Vips.block_untrusted`, which are indistinguishable at the call site. BC4 stores the message as
durable metadata specifically so it can re-scan later with a newer libvips. For that to be worth anything
the record has to carry enough to re-decide on: the code, the error class, and the message.

`killed` requires the supervisor to hold its copy of the accepted connection until the child exits, and
to write the response itself when it reaps a child that did not exit zero. A killed worker cannot
report its own death, because `RLIMIT_FSIZE` and the deadline `KILL` are enforced by a signal. The cost is one
held descriptor per in-flight request, bounded by `concurrency`. Without it the cold side sees a bare
end of stream and cannot tell a limit breach from a crash — which is exactly what the prototype behind
this document did, and why the ambiguity is worth a protocol field to remove.

**`ok: true` with an empty output is a failure, and the client must check.** The worker flushes before
reporting success, so this should not happen — which is precisely why it must be handled rather than
assumed away. Zero bytes written to an output descriptor is transient, not a valid empty image. A disk
full on the cell's tmpfs arrives this way too, as `ENOSPC` from the copy rather than from the socket, and
a full filesystem must never be recorded as "this document is unprocessable."

### `error.message` is untrusted, and it outlives the request

The message comes out of a worker that has just parsed a hostile file, and `Vips::Error#message` routinely
contains the input filename. BC4 stores these messages as durable blob metadata. So an unscrubbed byte
sequence becomes a permanently poisoned database row, and an invalid UTF-8 sequence makes a downstream
regex raise `ArgumentError` instead of answering false. Three requirements:

1. **Cap it in bytes at the cell**, before it goes on the wire.
2. **Force UTF-8 and scrub it at the client**, before it reaches an exception message. Note that
   `JSON.parse` does not raise on an invalid UTF-8 sequence, so parsing is not a filter.
3. **Test that it carries no document bytes**, with a marker string planted in a fixture. A review cannot
   establish this and an eyeball cannot either.

**Decide now whether `error.message` is contract.** The first consumer that matches on it freezes it
forever — and there will be one, because a password-protected PDF is distinguishable no other way. Either
declare the message non-contract free text and add a structured field for every case a consumer would
otherwise regex, or accept that the wording is now versioned. Choosing by accident is the bad outcome.

## 4. `hotcell-server`

### `HotCell::Operation`

The operation declares only what is not an argument.

```ruby
class TransformImageOperation < HotCell::Operation
  operation "active_storage.transform_image"     # defaults to the underscored class name, minus the suffix

  limits deadline: 30, memory: 1280 * 1024**2, file_size: 48 * 1024**2, open_files: 256

  before_fork        { require "image_processing/vips" }
  before_worker_boot { Vips.concurrency_set 4; Vips.block_untrusted true; Vips.cache_set_max_mem 10 * 1024**2 }

  def perform(inputs, outputs, payload)
    source, = inputs
    destination, = outputs
    validate! payload            # plain Ruby; see below
    …
    { width:, height:, bytes:, content_type: }
  end
end
```

`operation` writes the name into a registry, and the `op` field on the wire is looked up in it. A
wire name is never used to derive a constant.

| Limit | Maps to | Notes |
| --- | --- | --- |
| `deadline` | none — the supervisor's clock | Wall-clock seconds this request may run. Not an rlimit. See below. |
| `memory` | `RLIMIT_DATA` | Not `RLIMIT_AS`, and not an RSS bound. Floor of 1 GiB. See below. |
| `file_size` | `RLIMIT_FSIZE` | Bounds **every** file the worker writes, which is the posted-in input copy as well as the output. One number, deliberately: the kernel does not distinguish them, so pretending the limit is only about outputs would just make it surprising. Size it for the larger of the two. |
| `open_files` | `RLIMIT_NOFILE` | |

**`memory` is `RLIMIT_DATA`, and the numbers are not intuitive.** All of the following was measured, on
Linux 7.1 with libvips 8.18 and Ruby 3.4, against a real 806×926 → 1200×1200 JPEG variant whose peak RSS
is 45 MB:

| | Floor that works | Overhead against 45 MB of real use |
| --- | --- | --- |
| `RLIMIT_AS` | ≥ 1536 MB | 34× |
| `RLIMIT_DATA` | 704 MB | 15× |

`RLIMIT_DATA` charges private *writable* anonymous mappings. It ignores `PROT_NONE` reservations,
read-only private file mappings, and `MAP_SHARED` of any kind. `RLIMIT_AS` charges all of them, which is
why it needs 34× headroom — and why it fails *nondeterministically* for a 400 MB band below its floor,
usually as `glib: Error creating thread`. **Do not set `RLIMIT_AS` at all**, not even as a backstop: any
value that clears the 2.2–2.4× `VmSize`/`VmData` ratio is already above the container's own memory limit,
so it is dead weight.

Two things make the floor as high as it is, and both are worth knowing before someone tries to lower it:

- **About 450 MB is Ruby.** Since 3.3, Ruby reserves a single ~404 MB writable anonymous region at boot
  that it never touches, and `RLIMIT_DATA` charges all of it. `RUBY_GC_HEAP_INIT_SLOTS` and
  `MALLOC_ARENA_MAX` do not change it, and 3.4 and 4.0 behave the same. So `memory:` is not "how much a
  bomb may consume" — subtract 450 MB before reading it that way.
- **Thread stacks are charged too, and this corrects a natural assumption.** A pthread stack is a private
  writable anonymous mapping, so `RLIMIT_DATA` charges it exactly as `RLIMIT_AS` does — 16.4 MB of
  `VmData` per thread at a 16 MB stack size. `RLIMIT_DATA`'s advantage over `RLIMIT_AS` is file-backed and
  `PROT_NONE` mappings, not stacks.

That last point has an actionable consequence: **set a small thread stack at container entry**, with
`--ulimit stack=2097152` on the accessory. It is worth roughly 140 MB per worker at concurrency 4. It
cannot be part of the `limits` DSL, because glibc snapshots `RLIMIT_STACK` at process init and a
`Process.setrlimit` call in the worker does nothing at all — the reported value changes and the behaviour
does not.

**Enforce a 1 GiB floor in the DSL, with a clear error.** Below the floor the worker does not fail
gracefully, it dies before it can answer, as `SIGABRT` or `Errno::ENOMEM` during boot. Someone will
otherwise set 512 MB for a thumbnail cell and get a cell that dies on every request.

**`memory:` and the container's memory limit are in different units, so do not multiply.** `RLIMIT_DATA`
bounds one worker's data *address space*, most of which is reserved and never resident. The cgroup limit
bounds *resident* memory across the whole cell, and it also counts the tmpfs and page cache, which
`RLIMIT_DATA` never sees. So size `memory:` from the floor — 1.5 GiB against a 2 GiB cgroup is the
recommendation — and size the cgroup from `concurrency × realistic peak RSS` plus the tmpfs. Keep
`memory:` strictly *below* the cgroup limit, because equal values mean the cgroup fires first and you get
the bare `SIGKILL` the rlimit existed to avoid.

Note the one place `memory:` looks like a resource bound and is not: `MAP_SHARED` and tmpfs-backed pages
are charged to neither rlimit, so the worker's scratch is bounded only by `file_size` and the cgroup.

**A memory breach is not reliably catchable, and the supervisor's reap path is what saves it.** About a
third of the paths measured kill the worker by signal rather than returning null: libvips 8.18 dereferences
null on its own out-of-memory path and takes `SIGSEGV` at `vips_image_decode`, *after* printing the correct
diagnostic, and GLib's non-nullable `g_malloc` aborts. So `memory` belongs with `fsize` as
something the supervisor reports from an exit signal, not only something a worker rescues. Both routes
write the same verdict:

- The worker rescues `NoMemoryError`, `Errno::ENOMEM`, and a `Vips::Error` matching out-of-memory, and
  answers `killed` with `cause: "memory"` and the library's own message as detail.
- The supervisor maps `SEGV`, `ABRT`, `TRAP`, and `KILL` to `killed` with `cause: "memory"` and the signal
  as a field. Same code, signal as data, so the cold side never parses a message to decide.

One message deserves naming because it is the commonest near-limit result and reads like something else:
**`glib: Error creating thread: Resource temporarily unavailable` is memory exhaustion in disguise** and
must be classified `killed`, never `failed`.

Finally, keep the container's cgroup limit, but for the reason the measurements support rather than the
one that sounds right. The OOM killer's badness score is RSS-proportional, and in every trial it chose the
allocating worker rather than the 26 MB supervisor. The real argument for the per-worker rlimit is
diagnostic: a cgroup kill carries no information at all, where `RLIMIT_DATA` yields
`vips_image_write_to_memory: out of memory -- size == 732MB` on the paths where libvips checks its own
return value.

**Put `Vips.tracked_mem_highwater` on every response.** It is the only number that tells an operator
whether `memory:` is sized correctly, because RSS understates the charge and `VmSize` overstates it by
2.3×. Without it the limit can only be tuned by trying values until requests stop dying.

**`before_worker_boot` is where an operation sizes its library, and the framework does not do it for
you.** `Vips.concurrency_set 4` in a cell allocated two CPUs, running twenty workers, is forty
threads on two cores. That is the operation author's problem to get right, against the cell's `cpus`
and `concurrency`. This design supplies the hook and the numbers, not the policy.

The two callbacks take their names and their semantics from Puma's cluster-mode hooks. `before_fork`
runs in the supervisor; `before_worker_boot` runs in the worker after the fork and before it does
anything.

**`before_fork` requires; `before_worker_boot` configures.** The split matters for two reasons.
`require` is idempotent, so preloading cannot conflict between operations. Configuration is global and
singular, so doing it in the supervisor would mean two operations silently disagreeing about concurrency
or cache limits, with the last one registered winning. In a worker there is exactly one operation, so no
conflict is possible. It is also safe: the fork hazard is libvips' thread pool, which has not started
yet.

**`before_fork` may require and may configure, but it must never evaluate.** This is the rule the whole
process model rests on, and its violation is a silent hang rather than a crash. Measured: a parent that has
only required `image_processing/vips` and called `Vips.concurrency_set` has three threads and forks
children that work; one additional 1×1 image evaluation takes it to five threads, and from then on **every
forked worker blocks forever in `futex_do_wait`.** Not the first one — every one. The GLib thread pool does
not survive `fork`, and the child waits on a pool with no threads. A later change that pre-warms the pool
to save the fork cost is exactly what this forbids.

**Do not call `Vips.block_untrusted` in `before_worker_boot`.** Pin `image_processing` to 2.0 or later
instead, which makes the call as it loads. It skips its own call when `VIPS_BLOCK_UNTRUSTED` is in the
environment, and measuring rather than reading is what settles that: libvips honours the variable itself, so the
unfuzzed loaders are blocked with it unset, set, or set to the empty string. Nothing an operation adds reaches a
state the require has not already reached. What no arrangement of that call covers is somebody calling
`Vips.block_untrusted false` afterwards, and a call at worker boot would not cover it either — an operation
could do it inside `perform`. Test the property instead: feed the cell an SVG, a BMP and an ICO and watch it
refuse all three.

**`before_fork` must also force loader-plugin registration, and `require "image_processing/vips"` is what
does it.** Plain `require "vips"` leaves the libheif plugins un-`dlopen`ed. They are then loaded lazily in
the worker — after its limits are on — and a tight `memory` limit makes `dlopen` fail with only a
`VIPS-WARNING`, after which the process runs on with HEIC and AVIF quietly missing. A resource-limit breach
becomes `unreadable` for an entire format family, which is the worst confusion the error taxonomy can
produce. `Vips.block_untrusted true` also maps them and spawns no threads, so either will do — but say which
and why, because the current spelling gets it right by side effect.

Order-dependence here is not hypothetical. Fizzy's `config/initializers/vips.rb` carries a comment
explaining that `Vips.block` must run after Rails and `image_processing` set their defaults, and it
force-loads a class to pin the order.

**`before_fork` runs once, at boot.** Puma forks its whole worker pool up front, so there "before the
fork" and "at boot" are the same moment. A hotcell forks per request, continuously, so they are not.
`before_fork` must not be read as running before each fork: the supervisor does exactly one pass over
its consist at startup and then never runs operation code again. Anything that happens per request
belongs in `before_worker_boot` or in `perform`. Putting per-request work in the supervisor is what
invariant 3 forbids, and it is the failure that deadlocks every subsequent worker.

There is deliberately no `after_worker_shutdown`. A worker calls `exit!` on purpose so that finalizers
and libvips teardown never run, which means a shutdown hook would invite cleanup code that is then
skipped. If one is ever added it has to run before that `exit!`, and the reason for the `exit!` has to
be preserved.

### Cell configuration, concurrency, and slots

A cell is configured once, and everything about scheduling lives there rather than on an operation.

```ruby
# the cell's own config, read at boot
HotCell.limits concurrency: 4, queue_size: 8, deadline: 60, queue_wait: 10, max_requests_per_worker: 1,
               memory: 1536 * 1024**2, file_size: 48 * 1024**2
```

| Key | Meaning |
| --- | --- |
| `concurrency` | Workers running at once. Also the number of slots. |
| `queue_size` | Accepted-but-not-running connections. Above `concurrency + queue_size` the answer is `capacity`. |
| `queue_wait` | Seconds a queued connection may wait before it is answered `capacity` instead. |
| `deadline` | Maximum wall-clock seconds a **request** may run. An operation may declare a shorter one; this clamps it. The supervisor kills the worker and answers `killed`. |
| `max_requests_per_worker` | Requests a worker serves before it is discarded. `1` is fork-per-request; `:unlimited` is a persistent pool. Small values already recover most of the cost. See "Worker max_requests_per_worker". |
| everything else | Maximums for the same keys an operation declares. An operation's `limits` are clamped to these. This is invariant 6. |

**Those numbers are arithmetic against the container's flags, not defaults to copy.** Against the
`cpus: 2`, `memory: 2g`, `tmpfs … size=512m` cell in section 2: `concurrency: 4` because the work is
CPU-bound on two cores; `file_size: 48MB` because four workers each holding an input and an output is
384MB against a 512MB tmpfs; `memory: 1536MB` because that is the measured working value for
`RLIMIT_DATA`, which is per worker and mostly reservation rather than resident bytes.

**`memory` does not multiply by `concurrency`, and this is the easiest mistake to make here.** It is an
address-space charge on one worker, and roughly 620MB of it is fixed cost that is reserved and never
touched. The cgroup limit is the one that bounds real memory across the cell, and it counts the tmpfs too.
Size them separately: `memory` from the floor, the cgroup from `concurrency × realistic peak RSS` plus the
tmpfs. See section 4, which has the measurements.

**Slots are a consequence of the concurrency limit, not a thing to configure.** At most `concurrency`
workers run, so number them `0` to `concurrency - 1` and hand each worker its number at fork. The slot
number selects two directories, both created at boot:

- **`$HOME`, reused.** Some tools cannot share one. LibreOffice keeps a profile under `$HOME` and
  corrupts itself when two instances share it, which
  [haystack#8538](https://github.com/basecamp/haystack/pull/8538) found and worked around with a fixed
  pool. A per-slot home makes that structural rather than a special case, and because it survives
  between requests the expensive profile is created once and is warm afterwards. That is the
  pre-warming benefit without a warming pass, and without the supervisor spawning anything.
- **Scratch, per request.** Where inputs are posted in. Created when the worker starts and removed
  when it finishes, and removed by the supervisor when it does not.

There is no leasing and no per-operation slot count. A slot is always free when a worker starts, because
the thing that bounds workers is the same thing that counts slots. A request never waits for a *slot*; it
waits in the cell's queue, which is a different thing with its own bound. See "Queueing".

**The reused home is a channel between requests, and that is an accepted cost.** Two requests that land
on the same slot share a directory, so one can leave a file the other reads. It buys the warm profile
and it is what makes a large tool usable at all, but it is the one place in this design where
requests are not fully isolated from each other, and it should be stated wherever it is relied on. What
bounds it: nothing sensitive belongs in a tool's home, and scratch is separate and per-request. An
operation that does not need a warm home is better off with a fresh one.

**The danger is what an earlier request wrote into that home, not what a later one reads out of it.** A
tool's user profile is configuration, and for LibreOffice the user layer composes last — so a write
into a slot's `$HOME` can plant settings that disable the tool's own hardening for every subsequent
request on that slot — measured on a built image, not hypothetical. An operation that reuses a home owes a
tool configuration the user layer cannot override, and a probe that confirms it.

Wiping a slot's home after a kill is the safe default and it is not free: for LibreOffice it reintroduces
the cold start that a warm profile exists to avoid, on the next request to that slot. Warming every slot
at boot and **failing the boot if any slot fails to warm** is the other half of the answer, and the
reason is not latency — it is that a broken profile would otherwise silently corrupt every conversion
that slot ever serves.

### Worker max_requests_per_worker

`max_requests_per_worker` is how many requests a worker serves before the supervisor discards it. **The point of it is
amortization**, and the amount is measured: a worker's first request pays a copy-on-write settling cost that
later requests in the same process do not, worth about a third of the request. It has effectively decayed by
the third request, so small values get almost all of the benefit and large ones buy nothing. See Appendix B.

The two things `max_requests_per_worker` trades between are both real, and neither is a formality:

- **Recycling bounds what a compromised worker can reach.** An input that achieves code execution can read
  and tamper with every later request its worker handles, with no race to win and covering requests that were
  never concurrent with it. `max_requests_per_worker: 1` is the only value where a request cannot reach another request.
- **Recycling costs a third of every request.** Paid on every single one, forever.

So `max_requests_per_worker` is a dial, `1` is one end of it, and the right value depends on the operation.

**What makes the difference is where the untrusted bytes are parsed.**

| | Where a malicious input executes | What recycling buys |
| --- | --- | --- |
| **Subprocess tool** — `soffice`, `mutool`, `ffmpeg`, ImageMagick's CLI | In an `exec`'d child that dies at the end of the conversion. The worker only copies bytes, spawns, and reads an exit status. | **Nothing.** The worker was never exposed. These cells can run persistent workers. |
| **In-process library** — libvips through `ruby-vips`, RMagick | In the worker's own address space. | **Isolation between requests.** So `max_requests_per_worker` here is a genuine security dial, and its value is a judgement about how much isolation a third of a request is worth. |

**This is a property of the operation's code, not something it declares.** An earlier draft had operations
declare `untrusted_input :in_process` or `:subprocess`, and a cell warned at boot when
`max_requests_per_worker` was above `1` and any operation claimed the first. That was withdrawn: the
declaration was an unverifiable self-assertion whose only consumer was a log line, and the assertion is easy
to break — reading a tool's output with an in-process library, or parsing its stdout, moves bytes a
hostile input produced back into the worker, with nothing to notice.

What survives is the reasoning, which belongs where an operation is written rather than in a keyword. The
question is narrow: can a malicious input *execute* in this process?

1. **Reading its own output with an in-process media library means it can.** Building `result` from the
   tool's output header — width and page height, which BC4's thumbnailer wants — runs a decoder over
   bytes a tool just produced from a hostile input, in the worker. `preview_pdf` and `preview_video`
   therefore return no dimensions at all, which is also what Rails' previewers return: a previewer yields
   `io:`, `filename:` and `content_type:`, and the dimensions come later from analysing the attached blob.
2. **Parsing the tool's structured stdout does not.** `probe_media` reads ffprobe's JSON, on a bounded
   buffer, with the standard library. Treating that as equivalent to an image decoder would make the category
   mean "touches any attacker-influenced byte", which is every operation — and a distinction that covers
   everything guides nobody. What it must do instead is refuse to pass that data on: only numbers and codec
   names matching a conservative pattern come back, because everything ffprobe reports is attacker-controlled,
   including title tags that need not be valid UTF-8.

`max_requests_per_worker` above `1` is therefore a judgement made by whoever runs the cell, against what that
cell carries. A cell doing avatar thumbnails for one tenant is a very different risk from one converting
arbitrary uploads across tenants.

**Reuse is simple here only because there is no `RLIMIT_CPU`.** A cumulative CPU limit would stop meaning
"per request" the moment `max_requests_per_worker` went above `1`, and would need a different answer for `:subprocess` and
`:in_process` operations. Since time is bounded by the supervisor's deadline instead, and the deadline is
measured per request from dispatch, `max_requests_per_worker` changes nothing about it. See "Time is bounded by the deadline"
in the operation limits above.

The limits that do survive a reused worker survive cleanly: `file_size` is per file, and `memory` is a
high-water bound on address space rather than a running total. A worker that leaks across requests will trip
`memory` eventually, which is the correct outcome and worth watching `tracked_mem_highwater` for.

Two smaller consequences. A deadline kill destroys a warm worker, which is correct — the supervisor replaces
it, and a hostile input therefore costs the pool one warm worker rather than anything durable. And the libvips
operation cache now spans requests inside one worker, so a cell with `max_requests_per_worker` above `1` should set it to zero
unless it has a measured reason not to: it is a place one request's image data can sit while the next runs.

### Queueing

`queue_size` exists so that saturation shows up as latency before it shows up as failure. At
`concurrency: 4, queue_size: 8` the cell runs 4 and holds 8 waiting; the thirteenth is refused. A
cell that only ever refused would go from healthy to erroring with nothing in between and nothing to
alarm on.

`queue_wait` is the other half, and it is the one that is easy to leave out. Without it a queued
connection waits until the *client's* timeout fires, so the client reports its own transport error and
the cell's `capacity` verdict is never delivered — meaning the code you built the queue to surface
becomes unreachable exactly when the cell is saturated. thimble shipped without this and documented the
symptom rather than fixing it. Bound the wait server-side so the verdict comes from the side that knows.

That makes the client's timeout a sum, not a comparison:

```
client timeout  >  queue_wait + deadline + kill grace
```

So the response reports queue time separately, and the client publishes it (see "Instrumentation"):

```json
"timing":{"queued_ms":0,"perform_ms":47}
```

Rising `queued_ms` is the leading indicator. `capacity` rate is the lagging one, and by the time you
see it users are already getting placeholders. Alarm on the first.

**Validation belongs to the operation, in plain Ruby.** Type checks are close to worthless: JSON
already admits only six types, and a wrong value reaches first-party code in a container with no
network. Two kinds of value are different, and it is not their type that matters. `operations` is
method-name dispatch into `image_processing`, so it is `public_send` with caller-supplied names.
`format` selects a libvips saver. Both need value allowlists, and an allowlist is not a type check.
Those allowlists are enforced here and again on the cold side, because one cell may serve several
applications carrying different policies.

### Supervisor

1. Read in every registered operation and run its `before_fork`. Create the slot homes.
2. Create both listening sockets. Log the consist and the cell's limits.
3. Wait for any of: a connection on either socket, a dead child, or the nearest deadline.
4. On a work connection: dispatch it to an idle worker, forking one first if none is idle and a slot is
   free. Otherwise queue it, or answer `capacity` and close if the queue is full. Record the dispatch time
   against that worker, and retain a copy of every connection it dispatched.
   On a control connection: dispatch against the control allowance instead, which is separate and small, so
   control never queues behind work and is never answered `capacity`.
5. On a worker reporting itself idle: dispatch anything queued, or retire it if it has served `max_requests_per_worker`
   requests.
6. On a dead child: free its slot, remove its scratch, and if it did not exit zero write `killed` on the
   retained connection with the elapsed time. Then dispatch anything waiting.
7. On a deadline, measured from the dispatch time of the request a worker is currently serving: `KILL` the
   worker. It comes back as a dead child.
8. On `INT` or `TERM`: stop accepting, refuse the queue, let running children finish, remove both sockets.

**Reap on `SIGCHLD`, not at the top of the accept loop.** This is the one part of the loop that is
easy to get wrong and whose failure is invisible in a smoke test. A worker killed by a resource limit
cannot report its own death, so the supervisor reports it — but if the supervisor only reaps when the
next connection arrives, an idle cell never reports it at all, and the caller waits out its full
timeout for a worker that died in the first second. Handle it with a self-pipe written from the signal
handler and read in the same `IO.select` as the listener, with the timeout set to the nearest deadline.
Then a death is a wakeup rather than something noticed later.

Everything the supervisor writes — `capacity`, `killed` — it *generates*. It reads nothing. Step 4
refuses without `recvmsg`, so the descriptors the client attached are discarded by the kernel when the
connection closes.

### Worker

1. Apply the **cell's** limits at once, before touching the socket.
2. Read the request and receive the descriptors. Resolve the operation in the registry. Answer
   `unsupported` for an unknown name or version.
3. Verify the descriptor count and the access modes. Answer `invalid` otherwise, and close every
   received descriptor either way, including any it will not use.
4. Run `before_worker_boot` for the resolved operation.
5. Narrow to the **operation's** limits, clamped to the cell's, **before reading any untrusted byte.**
6. Run `perform`, timing it. An input copies itself to the scratch directory in the worker's slot when
   the operation first asks for its path, and never otherwise.
7. Post the outputs and flush.
8. Write the response with the timing, remove the scratch directory, and report itself idle.
9. At `max_requests_per_worker: 1`, or once `max_requests_per_worker` requests are served, exit without running finalizers.

At `max_requests_per_worker: 1` steps 2 through 8 happen once and step 9 is immediate, which is the same shape as a worker
that exists only for one request. Above `1` the worker loops over steps 2 to 8, and `before_worker_boot`
still runs once — after the fork, before the first request.

**Set the soft limit and leave the hard limit at the cell's ceiling.** An unprivileged process can raise a soft
limit up to its hard limit and can never raise a hard one, so setting both to the operation's value would make
the first request the tightest a reused worker could ever be — a later operation with a larger budget could not
get it back, and `setrlimit` with a soft limit above the hard one is `EINVAL`, which kills the worker before it
can answer.

Limits are applied in two passes for a reason. The worker has to parse the request before it can know
which operation's limits to use, and parsing is the first thing it does with attacker-influenced bytes.
So the cell's maximums go on first, at a point that needs no parsing at all, and the operation's
tighter set replaces them once the operation is known. The 8192-byte request cap and an explicit low
`max_nesting` are what bound the parse itself.

**Every tool subprocess is spawned with `unsetenv_others: true` and a fully written environment**,
never a filtered copy of the worker's own. This is invariant 9. Filtering would not work: the worker is
forked, so its `/proc/self/environ` is fixed and `ENV.delete` does not change what anything reads. An
`exec`ed child is different, and writing its environment in full is the only point where we control
what a tool's `/proc/<pid>/environ` shows.

Staging inputs to scratch is the general model, not a workaround. Every subprocess tool wants a path:
`image_processing` is filename-in and filename-out, and mutool, ffmpeg, and ffprobe take paths. Copying
gives the tool a path the cold side never named.

**The copy happens on demand, and for large inputs it has to be avoidable.** An input stages itself
when the operation first asks for its path, so an operation that can consume a descriptor directly —
`ffprobe` reads only a container header — never copies a multi-gigabyte input onto a 512MB tmpfs first.
That is not a corner case: it is the reason thimble's video role abandoned descriptors for a read-only
shared volume, having measured the alternative at roughly 300× I/O amplification on its commonest call.
An operation that does ask for paths is bounded by the cell's tmpfs, and that bound has to be sized
against `concurrency`, not against one request.

Limits are per-operation because one set does not fit. Thirty CPU seconds suits a JPEG, is far too
generous for analysis, and is hopeless for video. The cell clamps every declaration against its own
maximums, so a video cell can allow minutes without an image cell having to.

**Time is bounded by the deadline, and deliberately not by `RLIMIT_CPU`.** An earlier version of this
document had a `cpu_seconds` limit alongside the others. It is gone, and the reasoning is worth keeping so it
does not come back by reflex:

- **The deadline strictly covers it.** Anything that burns CPU also burns wall clock. The deadline also
  catches a worker blocked on a wedged subprocess, deadlocked, or waiting on something that never arrives —
  none of which trips `RLIMIT_CPU`, because a stuck worker consumes no CPU at all.
- **Two numbers, related by a factor nobody can predict.** CPU time over wall time measures 1.0× at libvips
  concurrency 1 and about 1.5–1.6× at 4 and 8, varying with the image. So a CPU limit cannot be derived from a
  latency budget; it has to be tuned separately, against a moving multiplier, and it will be tuned wrong.
- **`RLIMIT_CPU` is cumulative over a process's life**, so it stops meaning "per request" the moment `max_requests_per_worker`
  goes above `1`. Removing it is most of what makes worker max_requests_per_worker simple.
- **Aggregate CPU is already bounded** by the container's `cpus`, which is the resource-exhaustion concern.

What is given up is real and worth naming: `RLIMIT_CPU` was kernel-enforced and would still fire if the
supervisor's timer logic were wrong or the supervisor itself were wedged. The deadline is one Ruby process's
correctness. That is an acceptable trade because the supervisor is a small loop whose failure stops the cell
serving anyway, but it is the reason to keep that loop boring.

**Note which limits are irreplaceable, because the distinction is the useful one.** `memory` and `file_size`
bound *magnitude*, and no time limit substitutes for them: a worker can allocate several gigabytes or write
tens of gigabytes well inside a sixty-second deadline. `cpu_seconds` bounded *time*, and there was already a
better bound on time.

Because the deadline is now the per-request time limit, it is an operation limit as well as a cell maximum.
The original reason for per-operation limits still holds — thirty seconds suits a JPEG, is far too generous
for analysis, and is hopeless for video — and `deadline` is what carries it. The cell clamps it, which is
invariant 6.

### Container image

The base image carries Ruby, the two server gems, and nothing else. It documents two extension points,
because operations need libraries it does not have. BC4 needs ImageMagick and RMagick for text
rendering, font glyph coverage, and `VipsImageExport`'s `magicksave_buffer` fallback for formats
libvips cannot write.

```dockerfile
FROM registry.37signals.com/basecamp/hotcell:latest

USER root
RUN apt-get update -qq && apt-get install --no-install-recommends -y imagemagick
USER hotcell

COPY operations /hotcell/operations
RUN bundle install
```

The base image owes a derived one a load path it scans for operation classes at boot, and a Gemfile
that picks up `/hotcell/operations/Gemfile` when present.

The socket directory must be owned by the cell's user *in the image*, so a named volume mounted there
inherits that ownership.

## 5. `hotcell-client`

### Registration and routing

Cells are registered once. A client class names the cell that serves it.

```ruby
# config/initializers/hotcell.rb
HotCell.root = ENV.fetch("HOTCELL_ROOT", "/run/hotcell")

HotCell.register "active_storage"                                 # root/active_storage/{work,control}.sock
HotCell.register "archiver", dir: ENV["HOTCELL_ARCHIVER_DIR"], timeout: 300
```

Both socket paths are derived from the root and the cell name, so the volume mounts are mechanical rather
than something to remember, and the two sockets cannot end up in different directories. The override is a
directory rather than a socket for the same reason. It exists for local development and anything that does
not fit the convention.

```ruby
class ArchiveFolder < HotCell::Client
  hotcell "archiver"
end

ArchiveFolder.perform_in_hotcell(inputs, outputs, payload)
```

Routing is a class-level declaration rather than a call-site argument, so call sites stay free of
deployment detail and several clients may name the same cell. The operation name defaults to the
underscored class name, minus a trailing `Operation`, and can be overridden — so a client named
`ArchiveFolder` and a cell-side `ArchiveFolderOperation` derive the same wire name. An unregistered
server name raises at call time.

`HotCell::Client#perform_in_hotcell` wraps each IO as `Input` or `Output`, validates the payload,
connects to its cell's socket, sends one request, reads one response, and translates `error.code` into
an exception or returns it as data per configuration.

### The two exception classes are injected, not owned

**A client takes `permanent:` and `transient:` as arguments, and the gem names neither.**

```ruby
HotCell.register "active_storage",
  permanent: ActiveStorage::PreviewError,
  transient: MyApp::ConversionTemporarilyUnavailable
```

The gem cannot choose these, because two applications already do irreconcilable things with the same
class. HEY puts `ActiveStorage::PreviewError` in an `UNPROCESSABLE_ERRORS` list and writes
`metadata["unprocessable"] = true`, which **no code path anywhere in that application ever un-writes**;
its `Timeout::Error` is in the same list. BC4 does something else entirely: it never marks at
representation time, and instead splits on the *cache header*, serving a file-icon placeholder with
`expires_in 100.years` for a permanent failure and `no-store` for anything else. It marks unreadability
at upload time instead, against known-fresh bytes, which is the better place for the decision.

So a gem that raised `PreviewError` for a capacity refusal would, on HEY, permanently destroy the
thumbnail of every blob viewed during a cell restart, with no recovery short of a hand-written backfill.
`permanent` on the wire is what tells the client which class to raise; injection is what stops the gem
from guessing. An application adopting HotCell should also revisit its own permanent list — HEY's
predates out-of-process conversion, where a timeout stopped being a property of the input.

**The transient class must not descend from the permanent one, and that needs a test rather than a
comment.** The inheritance graph *is* the classification, so a later tidying pass that gives both a
common ancestor silently reintroduces the bug. Assert the exclusion: `refute transient <= permanent`.

Two more classes the client raises that are neither, and both must be enumerated rather than discovered:

- **A mapping or usage bug** — a payload value that is not JSON-native, a descriptor with the wrong
  access mode, a cell that does not carry the operation. These are the gem's own `ArgumentError`-shaped
  failures and they must be raised *outside* the transport rescue. Otherwise an application that injects
  a transient class descending from `IOError` gets its own bad call reclassified as a socket failure and
  retried forever.
- **Contract skew** — `protocol`. This one needs its own reporting hook, because both HEY and BC4 rescue
  broadly around representations, so "raise" is indistinguishable from "placeholder" and the skew is
  invisible. Give the client an `on_contract_skew` callback, handed the exception before it is raised,
  and wire it to `Rails.error.report(handled: true)` with the client's label. An application running
  several clients against several independently-booted cells needs to know *which* one skewed.

Anything the client can raise that the consuming application does not classify becomes a user-facing
500. That is not hypothetical: HEY has a `rails_ext` that exists because `system(exception: true)` raised
a bare `RuntimeError` outside its rescue list. Enumerate every class, including `Errno::*` from the
socket, and require each to be classified.

### Never retry in the client

The client must not reconnect and retry a request itself. "One request per connection" invites exactly
that on `ECONNREFUSED`, and a silent retry doubles a cell's load at the moment it is least able to take
it. Retry belongs in the job layer, which is the whole reason the transient class exists.

For the same reason, enforce any size ceiling on **both** sides. A limit only at the cell arrives at the
client as a truncated write, which classifies as transient, which is retried forever.

### The client timeout is a tradeoff, and it goes both ways

The obvious rule is that the client's timeout should exceed `queue_wait + deadline + kill grace`, so the
cold side never abandons a worker that is still legitimately running and always receives the cell's own
verdict. thimble deliberately chose the reverse, and wrote down why: holding a Puma thread is what its
timeout patch existed to bound in the first place.

Both are defensible, and the choice is per call path rather than per cell:

- **A synchronous representation request** wants the client bound *tighter* than the cell. A thread held
  for sixty seconds is a thread not serving traffic, and enough of them stop the process serving at all.
- **A background job** wants the client bound *looser*, so it gets `capacity` or `killed` and can act on
  it rather than guessing from a socket error.

This is safe only because both outcomes are transient, so neither is misclassified. `timeout` is
therefore per-registration, and the spec's obligation is to state what each setting buys rather than to
pick one.

**When the client does abandon, the supervisor must notice and kill the worker.** A closed connection
with a worker still running is a slot burning for output nobody will read. Detect it and treat it as a
cancellation — worth its own counter, since it is invisible on the wire by definition.

### Rollout

**Every path moves behind its own flag, and the flag is the cell's socket directory.** Unset means run
in-process exactly as today. This is the whole rollout mechanism, and it is worth copying precisely
because haystack#8546 has already shipped it:

- **Read the flag at call time, not at boot.** Then flipping it is a configuration change rather than a
  release, and reverting is the same. A flag consulted in `HotCell.register` makes every flip a deploy.
- **Install the integration unconditionally.** The patch, the analyzer, the previewers all go in on every
  boot. Only the flag decides whether a socket is dialled. Shipping the code dark and the switch separately
  is what makes the first flip cheap and the revert instant.
- **Cut one flag per failure profile, not per cell.** Variants, PDF previews, video previews, and analysis
  regress in different ways and must each be revertible alone, even when several share one cell. A flag per
  accessory couples things that fail independently.
- **Require a negative test on every flag.** With the flag unset: no connection is attempted, *and* the
  local failure mode still classifies correctly. The second half is the one that gets skipped, and it is
  what catches an integration that quietly changed the in-process path.

Ship with every flag off. Then the merge changes nothing in production, and each switch afterwards is a
one-line configuration change with a known way back.

One sequencing rule, because the failure between the two steps is silent: **the `accept?` overrides land
and are verified before any tool binary leaves the app image.** See section 6.

### The control channel

Two built-in operations, on `control.sock` rather than `work.sock`. They are the only things a cell answers
that are not conversions, and between them they cover the health check, the configuration-drift check, and
metrics.

**`hotcell.describe` — static, called once at boot.**

```json
{"v":1,"op":"hotcell.describe","inputs":0,"outputs":0,"payload":{}}
{"v":1,"ok":true,"result":{"v":1,"deadline":60,"queue_wait":10,"concurrency":4,"queue_size":8,
                           "operations":["active_storage.transform_image","…"]}}
```

The client calls it once per registered cell at boot and **logs a warning when its own `timeout` is below
`queue_wait + deadline + kill grace`**, naming both numbers. It is also the cheapest way to catch a client
pointed at a cell that does not carry the operation it wants, which is otherwise a runtime `unsupported` on
the first real request.

Boot must not fail when a cell does not answer. A cell that is down at app boot is a degraded deployment,
not a broken one, and an app that refuses to start because its thumbnail cell is restarting is worse
than one that serves placeholders. Warn, and carry on.

**`hotcell.metrics` — counters and gauges, polled.**

```json
{"v":1,"op":"hotcell.metrics","inputs":0,"outputs":0,"payload":{}}
{"v":1,"ok":true,"result":{"uptime_s":81043,"running":3,"queued":1,"queue_high_water":7,
                           "requests":{"total":184062,"ok":182122,"unreadable":1902,"killed":31,"capacity":7},
                           "killed_by":{"cpu":19,"fsize":0,"memory":11,"deadline":1,"signal":0},
                           "cancelled":14,"tracked_mem_highwater":58720256}}
```

This is a pull channel on purpose. A cell cannot push anywhere, so the application polls it and re-exports
through whatever it already uses — Prometheus, Yabeda, a structured log. The gem publishes numbers and
stops there, exactly as it does with `ActiveSupport::Notifications`.

Three of these are not derivable from the client side, which is the reason the channel exists at all:
`queue_high_water` is the leading saturation signal and no single caller sees it; `killed_by` separates a
decompression bomb from a slow afternoon in aggregate; and `tracked_mem_highwater` is the only number that
says whether `memory` is sized right, since RSS understates the charge and `VmSize` overstates it.
`cancelled` counts callers that gave up before the cell answered, which by definition appears on no
response.

**The supervisor answers these itself, rather than forking a worker for them.** An earlier draft forked, on
the reasoning that a child inherits the counters at fork and can report them without being told — which works,
and is beside the point. The whole value of this channel is being available when nothing else is, and a channel
that needs a fork to answer goes quiet exactly when a fork is what is failing. Neither built-in takes a
descriptor, touches a tool, or evaluates a byte of image data, so none of the reasons the supervisor stays
out of a conversion applies here.

It reads the control request to route it, which is the one thing the supervisor does parse. That is a bounded
line from the trusted side and it starts no thread pool, so it cannot deadlock a later fork.

**Read it without blocking.** The hazard is a half-sent line rather than silence: the socket becomes readable
once and then never again, so a blocking read would park the loop every conversion depends on. Bound the number
of connections waiting to speak, too.

**The control channel has its own small concurrency allowance and its own short deadline**, independent of
`work.sock`. A scrape must not queue behind conversions and must not be answered `capacity`, because a
metrics channel that goes quiet under load reports the same thing as a dead cell. Neither built-in takes
descriptors, reads a payload, or touches a tool, so none of the reasons for the work socket's limit
apply to them.

### Instrumentation

The client gem depends on `activesupport` and instruments through
`ActiveSupport::Notifications`, so an application subscribes with the mechanism it already uses.
`hotcell-server` does not depend on `activesupport`; a cell writes structured JSON lines to stdout with
the standard library, because there is no reason to load ActiveSupport inside a sandbox. See "Observability
under `network: none`" for why stdout is enough.

One event wraps the whole call, named for the Rails convention of `event.library`:

```ruby
ActiveSupport::Notifications.instrument "perform.hot_cell", payload
```

The payload carries what you need to answer a latency or capacity question without a second query:

| Key | Why |
| --- | --- |
| `operation` | The wire name. |
| `cell` | The server name, so per-cell latency is separable. |
| `code` | `nil` on success, otherwise the `error.code`. |
| `bytes_in`, `bytes_out` | Cost correlates with size far more than with operation. |
| `perform_ms` | The cell's own measurement, from the response's `timing`. |
| `timing` | The whole map, so a subscriber can raise child spans from the cell's breakdown. |

The subscriber's own duration minus `perform_ms` is transport plus queueing. Those two want separate
metrics: a rising `perform_ms` means the work got more expensive, and a rising difference means the cell
is saturated.

**`code` must be on the event, not only on an exception.** A cold side configured to treat `unreadable`
as data rather than as an error would otherwise make those requests invisible, and `unreadable` rates
are exactly what you want to watch after a libvips upgrade. `capacity` matters for the same reason:
without its rate you cannot size a worker pool.

Bridging these to Prometheus, Yabeda, or a structured log is the application's job, not the gem's. The
gem publishes events and stops there.

### Observability under `network: none`

A cell has no network, so nothing inside it can dial a collector. That rules out an in-process Sentry SDK,
an OTLP exporter, and a profiling agent. It rules out less than it first appears to, and the distinction is
worth being exact about because getting it wrong invites someone to give the cell a network for no reason.

**Stdout is not a network.** It is a pipe to the container runtime on the host, and the log driver runs in
that daemon with the host's network. So logs ship normally under `network: none` — journald, fluentd,
whatever the host already does. A cell writes structured JSON lines and gets a real log for free.

Three channels, and they cover between them everything except a profiler:

| Channel | Carries | Who exports it |
| --- | --- | --- |
| Structured stdout | One line per request, plus what no request sees: deadline kills, reaps that found a signal, boot checks, queue high-water. | The host's log driver. |
| The response | `timing` with its breakdown, `error` with code, class, message and optionally a backtrace. | The client, into the application's own tracer and error reporter. |
| `control.sock` | Counters and gauges, and the cell's own configuration. | The application, by polling and re-exporting. |

So the application is the only process that needs an exporter, and it already has one. It reports on the
cell's behalf, from data the cell handed it.

**What is genuinely lost: continuous profiling.** A profiling agent has to dial out, and there is no way
around that in a response. If that becomes necessary, the cheap answer is a collector on a second Unix
socket, not a network — spend a mount rather than an interface.

**Do not trade `network: none` for telemetry.** It is the only property here that is binary and auditable:
either the container has interfaces or it does not. The alternative is an egress ACL that has to stay
correct forever, on the code we trust least. haystack#8546 is the cautionary case — its accessory carries an
OTLP endpoint and a Sentry DSN, and its own deploy configuration says the accessory must first be moved to a
network with no route to the internal one, and that nothing arranges that today. That precondition is still
open, and observability is what bought it.

Note that the Active Storage adapters nest inside Active Storage's own
`transform.active_storage` and `analyze.active_storage` events, so a subscriber to both should not add
the two together.

## 6. `activestorage-hotcell-client`

Three classes an application configures Rails with, each a `HotCell::Client`.

```ruby
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Vips
config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::PdfPreviewer,
                                     ActiveStorage::HotCell::Client::VideoPreviewer ]
```

`variant_processor` accepting a class is [rails/rails#58384](https://github.com/rails/rails/pull/58384),
unmerged at the time of writing, and this gem depends on it. `analyzers` and `previewers` already accept
classes. Note what the failure looks like without it: `engine.rb`'s `case` has no `else`, so a class value
leaves `ActiveStorage.variant_transformer` at `nil` and the first variant dies with `NoMethodError` — not
a boot error.

**Neither obvious workaround works, so nobody should reach for one.** Both were measured on a booted
application, not reasoned about:

- Assigning `ActiveStorage.variant_transformer` from an application initializer is **silently overwritten**
  during boot, because Active Storage assigns it from a `config.after_initialize` hook that runs later. So
  does assigning it from the application's *own* `config.after_initialize`, since the application's
  railtie hooks run before the engine's.
- Prepending onto whatever `ActiveStorage.variant_transformer` resolves to, from `to_prepare`, **raises**:
  `to_prepare` runs strictly earlier than `after_initialize`, so the value is still `nil`. A prepend seam
  has to name the concrete transformer class, which is what haystack#8546 does.

**So assert at boot that this gem is actually installed** in `ActiveStorage.variant_transformer`'s
ancestry, whatever seam is used, rather than trusting that a configuration assignment took effect.

One factual note about what adopting this does and does not achieve, because it is easy to assume
otherwise: **`libvips` is loaded into the application process by `require "active_storage/engine"`**,
before any configuration is read. The engine builds its default analyzers array by eagerly referencing
`ActiveStorage::Analyzer::ImageAnalyzer::Vips`, which requires `ruby-vips`, which dlopens the library. No
`variant_processor` value changes that. Getting the library out of the application means removing
`ruby-vips` from the bundle, which then breaks that default array. Whether that is worth doing is the
application's call; what is not available is doing it by configuration alone.

`Transformers::Vips#process` must return an open `Tempfile`, per `ActiveStorage::Transformers::Transformer`.

### Rails supplies no degradation, and three gaps to close

**Rails serves a 500 for every representation failure.** There is no framework placeholder. The only
`head :not_found` is a `FileNotFoundError` raised while streaming something already processed;
`PreviewError`, `InvariableError`, `UnpreviewableError`, and `IntegrityError` all escape
`set_representation`'s `before_action` uncaught. HEY's placeholder and BC4's file-icon SVG are both
application code. So this gem cannot rely on any framework-provided degradation, and the spec must say
so rather than implying one exists.

**Gap 1, the analyzers.** The built-in image analyzers gate on `variant_processor` being `:vips` or
`:mini_magick`, so a class value makes `accept?` false, `analyzer_class` falls through to
`NullAnalyzer`, and the blob is marked `analyzed: true` with no dimensions. Shipping `ImageAnalyzer` is
therefore **mandatory, not a nicety** — #58384 deliberately leaves this to us.

There is a sharper version of the same problem inside the built-in vips analyzer: it rescues every
`Vips::Error` and returns `{}`, which is then merged with `analyzed: true`. An undecodable image is
silently recorded as successfully analyzed, forever, and nothing re-enqueues `AnalyzeJob`. So
`ImageAnalyzer` must be deliberate about which way it fails: `unreadable` follows the built-in behaviour
and marks the blob analyzed, ideally recording the message the way BC4 does; a transient code **must
raise**, so the blob stays `analyzed: false` and is eligible to be tried again.

**Gap 2, the previewers.** `accept?` must not probe for a binary.
`ActiveStorage::Previewer::MuPDFPreviewer.accept?` calls `mutool_exists?` and `VideoPreviewer.accept?`
calls `ffmpeg_exists?`, both shelling out with `system` from inside a web request. Once the binaries leave
the app image both answer false, `previewable?` goes false with them, and previews stop existing with no
exception and no alert.

The override must **delegate to the superclass's content-type predicate** rather than restate the list,
so the accepted set cannot drift. And the sequencing is part of the requirement: the override ships and is
verified *before* the binary leaves the app image, because the window between those two events fails
silently.

**Gap 3, the jobs do not retry anything useful.** `TransformJob`, `AnalyzeJob`, and `CreateVariantsJob`
declare `retry_on ActiveStorage::IntegrityError` and nothing else, and ActiveJob has no default retry. So
`capacity` — the one code whose whole point is "try later" — fails its job outright on the first attempt.
This gem must ship the `retry_on` for the transient class, or the spec must say the application owns it.
Prefer a server-suggested backoff over `:polynomially_longer`, whose ~3s first retry against a cell
already answering `capacity` is a thundering herd.

**Immediate variants have no job and therefore no retry at all.** `preprocessed: true` and
`process: :immediately` run `CreateVariantsJob.perform_now` inside the upload request, and nothing records
that the variant was wanted, so nothing re-enqueues it. On that path a transient code must be caught and
degraded to `perform_later`, **never raised** — otherwise a cell restart is a fleet-wide upload outage.

### Errors, and the mapping that must not be a single class

The client raises the injected `permanent:` and `transient:` classes described in section 5. This gem's
job is to map codes onto them and to say what is served:

| Code | Class | Served | Cached |
| --- | --- | --- | --- |
| `unreadable` | permanent | placeholder | cacheable |
| `killed` with `limit` `fsize`/`memory` | permanent | placeholder | cacheable |
| `failed` | permanent by default, overridable | placeholder | cacheable |
| `killed` with `cause: deadline`/`crashed`, `capacity`, `unavailable`, `timeout`, `unsupported` | transient | placeholder | **`no-store`** |
| `protocol` | permanent, **and report contract skew** | placeholder | `no-store` |
| `invalid` | neither — a caller bug | raise | — |

**The cache header is half the mapping and is easy to omit.** A transient failure served with a normal
cache header is a permanent failure with extra steps, at every intermediary. BC4 already does this
correctly, with `no-store` for a transient failure and `expires_in 100.years` for a permanent one, plus a
client-side poller that re-probes a placeholder a few times. Copy the split.

The specific trap: `ActiveStorage::Representations::ProxyController#show` wraps its response in
`http_cache_forever public: true`. A placeholder rendered from inside `show`, rather than from the
`set_representation` `before_action`, is cached forever everywhere.

## 7. `activestorage-hotcell-server`

Operation implementations, and the gem BC4 extends. At minimum `transform_image`, `analyze_image`,
`preview_pdf`, `preview_video`, `probe_media`.

**`loader` and `saver` reach the library, and that is a deferred decision rather than a settled one.**
`transform_image` builds `loader(page: 0)` first, so a hundred-frame GIF is not decoded in full to make one
thumbnail, and a caller's own `loader` merges over it through `apply` — which is exactly how Rails composes the
two. Every other key is checked against the operation's allowlist of transformation names.

The intended end state is an explicit allowlist of what may appear *inside* `loader` and `saver`: `page`, `n`,
`quality`, `strip` yes; `unlimited`, `access`, `fail-on`, `revalidate` no. Deriving that list is non-trivial and
it is a feature on its own. Until it exists, pass-through is Rails' behaviour inside a sandbox, which is
strictly better than Rails' behaviour outside one.

Worth knowing while reading old URLs: top-level `quality` and `strip`, and `coalesce`, all raise on the vips
path. They only ever worked on `mini_magick`, which is where they come from, and making them work again is the
ImageMagick-compatible transformer rather than a translation table.

**Upstream reached the same conclusion, for a narrower reason, and the gap it left is the argument here.**
Rails commit `1ca278a6` removed `apply`, `loader`, and `saver` from
`ActiveStorage.supported_image_processing_methods` as
[CVE-2025-24293](https://nvd.nist.gov/vuln/detail/CVE-2025-24293), backported to 7.1, 7.2 and 8.0. Be
precise about the scope, because it is easy to overclaim: that advisory is ImageMagick command injection,
and it names `mini_magick` specifically. It says nothing about vips.

And **on the vips path the removal is inert**, because only the ImageMagick transformer enforces the
allowlist at all — `ActiveStorage::Transformers::Vips` does not override `validate_transformation`, so it
accepts `loader`, `saver`, and `apply` today. Verified by probe, not inferred. That is the real argument:
a vips application has *no* transformation allowlist, so an operation's own allowlist is not a second line
of defence, it is the only one.

The compatibility squeeze is nonetheless live, on the `mini_magick` side. HEY runs `:mini_magick`, so the
allowlist binds, and it has three live URL-minting call sites passing `loader: { page: nil }` — so it
**re-adds `loader` to the allowlist in an initializer** to keep animated GIFs working. Moving that
application into a cell does not by itself resolve the squeeze; what resolves it is that a cell running
`mini_magick` cannot reach a shell worth injecting into.

**The client passes the transformations hash through, and this was tried the other way first.** A variant's
address is a signed serialization of the whole transformations hash, carried inside the URL itself rather than
looked up server-side, and it never expires. So an email sent last year carries
`loader: { page: nil }, coalesce: true` and will still decode to that hash in five years, and the app hands it
straight to the transformer. The client therefore held a mapping table from every historical shape onto a closed
payload — `loader: { page: nil }` plus `coalesce: true` became `animated: true`, and so on.

**That table was withdrawn, because it was two unbuilt features wearing one coat.** Dropping `loader` and
`saver` was a partial, implicit allowlist. Translating `coalesce` was partial, implicit ImageMagick
compatibility. Neither was complete, and together they meant an unrecognised library keyword was silently
dropped and the variant came back subtly wrong rather than refused. Both belong in the open: an explicit
allowlist of what may appear inside `loader` and `saver`, and an ImageMagick-compatible transformer and
analyzer alongside the vips ones. Until those exist the client passes the hash through, which is what Rails
does, and an application that has mini_magick-shaped URLs rewrites them at its own boundary the way BC4's
`RewriteTransformations` already does.

**Pass-through is acceptable here and not in a plain Rails application, and the reason is the sandbox.** A
caller can set `loader: { unlimited: true }`, which removes libvips' own denial-of-service limits — the same
capability Rails gives a caller today. The cell's limits are outside the library: `RLIMIT_DATA`,
`RLIMIT_FSIZE` and the supervisor's wall-clock deadline still apply, so a decode libvips has been told not to
bound costs the caller a killed worker and a transient verdict. The operation's own allowlist of transformation
names still stands, and it remains the only one on the vips path.

**Changing the hash for new callers is not free either.** It mints a new URL segment and a new
`variation_digest`, so every `variant_records` row for the old shape is orphaned — still attached to the blob,
reaped only when the blob is deleted. With `track_variants` off, the stored object key is variation-derived too
and those objects are orphaned as well. Budget for a doubled variant footprint on touched blobs rather than
pricing the change at zero. Hash insertion order counts as well: reordering the same three pairs mints a
different key.

Three details of the mechanism, each of which has bitten someone:

- **The signed hash is the *merged* one.** `default_to` injects `format:` before the key is computed, so
  what gets signed is not what the caller wrote.
- **The URL key and the database digest are different serializations of the same hash** — signed JSON for
  the key, `SHA1(Marshal.dump(…))` for the digest. They can therefore disagree: a Symbol-valued
  transformation leaves the URL key byte-identical while changing the digest, which is enough to produce two
  `variant_records` rows behind one URL. Pre-existing Rails behaviour, not something HotCell introduces, but
  it will distort any measurement of "variants generated" and is worth knowing before trusting one.
- **`variant_processor` does not participate in the key at all.** So a cutover keeps every key stable while
  changing the bytes: already-materialised variants are served as-is forever, and the application serves a
  permanent mix of pre- and post-HotCell output under identical URLs. There is no key-level cache buster
  short of changing the transformations hash.

And one scheduling constraint: `secret_key_base` *does* participate, as does the message serializer. So a
HotCell rollout must not be scheduled alongside a secret rotation or a serializer default bump, either of
which asks the cell to regenerate the entire corpus at once.

Otherwise `transform_image` builds
`source(path).loader(...).convert(format).apply(operations)`, matching
`ActiveStorage::Transformers::ImageProcessingTransformer`.

This gem must not load `activestorage`, despite its name. The name says which consumer it serves, not
what it links against. Invariant 1 covers it.

### What BC4 needs beyond this gem

Its Active Storage paths extend this gem. Three other things extend `hotcell-server` directly, and the
base operation class must serve them with no Active Storage underneath:

- **Avatar rendering.** Composites an application asset over a blob. Two inputs, one output.
- **Initials avatars.** Renders text with RMagick using a font chosen by glyph coverage. No inputs,
  one output, and the payload is a string of at most three characters.
- **Zip export.** `ZipScriptRunner.archive_folder` turns a directory tree into an archive. See open
  questions.

BC4's `VipsImageMetadata` also produces far more than Rails' analyzer: `pages`, `loader`, `mime_type`,
`web_image`, `animatable`, `animated`, `bits_per_pixel`, and dimensions derived from EXIF *and* XMP
orientation. Its `set_xmp_orientation!` writes an orientation field before processing while its patched
`autorot` strips XMP after, so there analysis and transformation are one operation, not two. `result`
carrying metadata alongside bytes is what makes that expressible.

## 8. Established by experiment

Each of these was measured, not reasoned about. A specification cannot derive them, getting them wrong
produces failures that are hard to diagnose, and each is cheap to confirm before relying on it. Confirm
them early: several of them constrain the architecture rather than the implementation.

1. **libvips cannot survive `fork` once it has evaluated an image.** After `require` and
   `Vips.concurrency_set` the process has three threads and forks children that work; the first image
   evaluation takes it to five, and from then on **every** forked child deadlocks in `futex_do_wait`,
   permanently. Reproducible. This is the whole reason for the `before_fork` and `before_worker_boot`
   split, and the reason `before_fork` may require and configure but must never evaluate.
2. **Two descriptors over `SCM_RIGHTS` work end to end**, with `Vips::Source.new_from_descriptor` and
   `Vips::Target.new_to_descriptor`, and the kernel enforces the access modes: writing an input or
   reading an output raises `Errno::EBADF`.
3. **Reopening `/proc/self/fd/N` defeats a read-only descriptor**, because it is a fresh `open`
   rechecked against the inode and does not inherit the original flags. Never use it to turn a
   descriptor into a filename. Copy instead.
4. **An empty Docker named volume takes its ownership from the image of whichever container mounts it**,
   even if an earlier container already mounted it, provided it is still empty. So accessory and app
   boot order does not matter. A bind mount instead takes the host directory's ownership, which is why
   local development needs the directory created first.
5. **Kamal 2.11 hard-codes `--network kamal` for app roles.** Only accessories accept `network`.
   Accessories can target `roles: [web, jobs]`, and are not updated by a deploy.
6. **A worker killed by a resource limit produces a bare end of stream**, which is why the supervisor
   must hold the connection and report `killed`. A `memory` breach does this too, roughly a third of the
   time: libvips 8.18 dereferences null on its own out-of-memory path and takes `SIGSEGV` at
   `vips_image_decode` *after* printing the correct diagnostic, and GLib's non-nullable `g_malloc` aborts.
   So the reap-and-report path carries `memory` as well as `fsize`.
7. **A sibling process's `/proc/<pid>/mem` is `EACCES` at `ptrace_scope = 1`, but its
   `/proc/<pid>/environ` is readable.** Verified with two same-UID siblings forked from one parent: the
   environ read returned the victim's canary. Yama restricts `PTRACE_MODE_ATTACH`, which `mem` needs,
   and does not restrict `PTRACE_MODE_READ`, which `environ` needs.
8. **A forked process cannot change what its own `/proc/self/environ` shows.** That view is the
   exec-time environment, so `ENV.delete` in a worker is invisible to a reader. Only an `exec`ed child
   gets a fresh one, which is why `unsetenv_others` on the tool spawn is the control.
9. **Docker cannot mount `/proc` with `hidepid`.** `--security-opt proc-opts=hidepid=2` is a Podman
   feature; Docker rejects it outright, and remounting inside the container needs `CAP_SYS_ADMIN`.
10. **LibreOffice corrupts itself when two instances share a `$HOME` profile**, per haystack#8538, which
    is the origin of slots. That PR also measures a hardened conversion at roughly 613ms and wraps
    production in `timeout --kill-after=60s 50s`, which sizes a soffice cell's deadline concretely.
11. **`RLIMIT_AS` is unusable and `RLIMIT_DATA` is expensive.** For a real variant whose peak RSS is 45MB,
    `RLIMIT_AS` must be at least 1536MB to succeed reliably and fails nondeterministically for a 400MB band
    below that; `RLIMIT_DATA` works at 704MB. `RLIMIT_DATA` charges private writable anonymous mappings and
    ignores `PROT_NONE` reservations, read-only private file mappings, and `MAP_SHARED` entirely. It does
    charge thread stacks, so shrinking `RLIMIT_STACK` at container entry is worth real headroom — and
    `RLIMIT_STACK` cannot be changed after `exec`, because glibc snapshots it at init.
12. **Ruby reserves about 450MB of `RLIMIT_DATA` at boot and never touches it.** A single ~404MB writable
    anonymous region, introduced in 3.3 and unchanged in 3.4 and 4.0, unaffected by the GC and malloc
    environment knobs. It is why the `memory` floor is what it is, and why `memory` cannot be read as how
    much a bomb may consume.
13. **A cgroup memory kill is a prompt, silent `SIGKILL` with no diagnostic**, and the kernel chose the
    allocating worker rather than the supervisor in every trial, because badness is RSS-proportional. The
    argument for a per-worker limit is the diagnostic, not the choice of victim.
14. **Plain `require "vips"` leaves the libheif plugins un-`dlopen`ed.** They then load lazily inside the
    worker, after its limits are on, where `dlopen` fails with only a warning and the process continues with
    HEIC and AVIF missing — turning a limit breach into `unreadable` for a whole format family.
    `require "image_processing/vips"` or `Vips.block_untrusted true` maps them in the supervisor instead.
15. **`fork` costs about 2.8ms**, measured as `fork` + `exit!` + `wait` from a 58MB three-thread parent with
    libvips required and never evaluated. It is a small part of the cell's fixed overhead, not most of it.
16. **The cell's fixed overhead is copy-on-write settling, and it is proportional to the supervisor's
    resident heap.** A worker's first pipeline run takes about 7,900 minor faults against 1,564 for a warm
    process. Forking the same work from a 265MB parent instead of a 58MB one took faults to about 25,900 and
    added roughly 52ms per request. So preloading generously in the supervisor makes every request slower for
    the life of the deployment. `RLIMIT_AS` and libvips thread-pool size were both tested and neither moves
    it.
17. **A reused worker pays that cost once, and it amortizes within three requests.** Per position in one
    worker's life: 68.5ms/7,907 faults, then 50.7/3,590, 38.3/1,875, 41.9/1,786, 40.8/1,220. A fresh worker
    every time is 71.2ms/8,004, matching the reused worker's first request, which confirms both arms measure
    the same thing. Over 70 transforms of identical work, timed from the parent so `fork` and reap count,
    max_requests_per_worker saved **27.3ms per transform, 36%**. Pre-warming with a synthetic image recovers only about a
    quarter of the faults and is not a substitute. See Appendix B.

## 9. Development

**Cells run uncontainerized in development.** Not as a fallback for macOS, but as the single
development story on every platform, so there is one thing to document and one thing to debug.

The reason is macOS and it cannot be engineered around. Docker Desktop runs containers in a Linux VM,
and a file descriptor is an index into one kernel's table. The macOS kernel and the VM's Linux kernel
are two kernels, so `sendmsg` has nothing meaningful to hand across. Native `AF_UNIX` and `SCM_RIGHTS`
on macOS work fine; it is specifically the host-to-VM boundary that cannot carry a descriptor.

So `hotcell-server` runs as a plain host process against a socket in the project's `tmp/`.

**What that gives you:** the real wire protocol, real descriptor passing, real fork-per-request, the
real operation API, and the real client integration. Everything except the isolation.

**What it does not give you:** `network: none`, `cap-drop`, a read-only root filesystem, the tmpfs
flags, or reliable `RLIMIT_AS`, which Darwin does not enforce dependably. A developer working on an
operation is testing the operation. The sandbox is verified on Linux, in CI and in the container suite,
and a change that touches hardening has to be tested there.

Tools have to be installed on the host, which they already are for the in-process path being
replaced.

### The inline transport

The client's transport is a seam with two implementations. `socket` is the default and the only one
used outside tests. `inline` skips the socket and the fork and calls `perform` directly, **but still
serializes and deserializes the payload**, so an application's unit tests can exercise operations with
no daemon running while marshalling bugs stay visible.

`inline` must never be the default development mode. Develop against it and you will ship payloads that
fail on the wire.

### Platform notes

- `sun_path` is 104 bytes on Darwin against 108 on Linux, and the development socket paths are
  repo-relative. A developer with a long project path will overflow it, with an error that does not say so.
  Check both paths at bind time and fail with a clear message. `control.sock` is the longer name, so it
  overflows first — check it rather than assuming `work.sock` is representative.
- `/run/hotcell` does not exist on macOS, so `HotCell.root` must be platform-aware or always explicit in
  development.
- **Verify before promising:** Ruby's `fork` on macOS can abort when a library has touched CoreFoundation,
  and Homebrew's libvips reaches it through glib. This is the one part of the native-cell plan that is
  assumed rather than tested.

## 10. Tests

**Test-driven wherever it is reasonable.** Write the failing test first, make it pass, then simplify.
Coverage here is not a metric to satisfy: this is security-relevant code whose failures are silent, so
a test that would still pass with the control removed is worse than no test, because it reads as
assurance.

### Making the suite run without the toolchain

Protocol and client behavior must be testable with neither Docker nor a real tool. haystack#8538
does this with a scripted stand-in for `soffice`, which lets 14 tests exercise the whole surface in
milliseconds. Do the same: a fixture operation that fakes the work, so only the end-to-end suite needs
a container.

### Required coverage

Not the nine invariants as a checklist. Five of them are plain to read in the code that implements them,
and a test that restates an obvious method is maintenance without assurance. The four worth testing are
below, and each is here for a stated reason: the kernel owns the behaviour, or it fails silently, or a
plausible refactor removes it.

- **Invariant 4**, because the kernel owns it: writing an input or reading an output raises `Errno::EBADF`.
- **Invariant 6**, because a clamp that silently stops clamping looks exactly like a clamp.
- **Invariant 8**, because it depends on a host sysctl and on Yama's exact access modes, neither of which is
  visible in our code.
- **Invariant 9**, because `unsetenv_others: true` is one keyword whose removal changes nothing observable
  in normal operation.

Invariant 1 is withdrawn — see the invariants above — so there is nothing to test or to check at boot.
- End to end against a containerized cell running with the accessory's flags, covering each request
  shape (two inputs, no inputs, no outputs), each `error.code`, and concurrent requests.
- A cell rejecting a read-write descriptor offered as an input.
- A payload whose *values* include a Symbol, a Time, and a custom object, each raising before
  serialization, and a payload with Symbol *keys* round-tripping to symbol keys inside `perform`.
- Limits: exceeding `file_size` yields `killed` rather than a truncated result, and an operation declaring
  above the cell's maximum is clamped to it.
- Two cells running concurrently, with a client routing to each, and neither able to reach the other's
  socket.
- Worker isolation: a sibling's `/proc/<pid>/mem` is `EACCES`, and the startup check reports loudly
  when `kernel.yama.ptrace_scope` is `0`.
- A tool subprocess's `/proc/<pid>/environ` contains only what the operation wrote, proving
  `unsetenv_others`.
- Concurrency: at `concurrency: 2, queue_size: 1`, two requests run together, a third waits and
  reports a non-zero `queued_ms`, and a fourth is answered `capacity`. Two requests on the same slot
  see the same `$HOME`; two running concurrently see different ones.
- The deadline, and **not with `sleep`**. A Ruby `sleep` is interruptible, so a deadline test built on one
  passes against a self-enforcing implementation that cannot actually work. Block the worker where Ruby cannot
  reach it and assert it is answered `killed`. Measured across the standard library: `sleep`, a Ruby spin loop
  and `Zlib::Inflate` are all interruptible, and `Integer#**` is not — `3 ** 40_000_000` runs for about seven
  seconds straight through a fifty-millisecond `Timeout`. That lets the cell's own suite hold this with no
  tool installed. Assert the premise in the test, so a Ruby that adds an interrupt check to that path
  reports it rather than quietly weakening the test. Two things are being
  tested: that the supervisor kills it at all, and that it does so **promptly**, with no other request needed
  to trigger the reap. The naive reap-at-top-of-accept-loop implementation fails the second.
- The deadline is per request, not per worker life: a worker that has already served several quick requests
  still gets the full `deadline` on its next one.
- Worker max_requests_per_worker: at `max_requests_per_worker: 3` the same pid serves three requests and a fourth arrives at a different pid.
  At `max_requests_per_worker: 1` every request gets a new pid.
- At `max_requests_per_worker: 3`, a second request landing on the same worker can observe state the first
  left behind. Write it as a **descriptive** test: it documents what the setting costs, which is the whole
  reason the number is a judgement rather than a tuning knob.
- A `perform.hot_cell` event is emitted for a success, an `unreadable`, and a `capacity`, each carrying
  `code`, `bytes_in`, `bytes_out`, `queued_ms`, and `perform_ms`.

On the client and the Active Storage side, where the failures are silent and permanent:

- The transient class does **not** descend from the permanent one: `refute transient <= permanent`. This
  is the test that stops a later tidying pass from reintroducing an irreversible bug.
- Every exception class the client can raise is classified. Enumerate them, including `Errno::*` from the
  socket and the gem's own argument errors, and assert none escapes unclassified.
- `error.message` carries no document bytes: plant a marker string in a fixture and assert its absence.
  Assert the byte cap, and assert an invalid UTF-8 sequence survives to a usable exception message.
- `ok: true` with zero bytes on the output is classified transient.
- A transient code produces a `no-store` response; a permanent one produces a cacheable response.
- The transient class is retried by `TransformJob` and `AnalyzeJob`, which retry nothing useful by default.
- On the immediate-variant path a transient code degrades to `perform_later` and does not raise.
- `accept?` on every previewer answers from content type alone, and delegates to the superclass predicate
  rather than restating the list.
- The integration is actually installed: assert this gem appears in `ActiveStorage.variant_transformer`'s
  ancestry, rather than trusting that the configuration assignment took effect.
- With a rollout flag unset: no connection is attempted, **and** the in-process failure modes still
  classify correctly.

And on the control channel, whose whole value is being available when nothing else is:

- `hotcell.metrics` answers on `control.sock` while `work.sock` is saturated **and its queue is full**. This
  is the test that justifies the second socket, and a single-socket implementation fails it.
- `hotcell.describe` reports the operations the cell actually carries, and the client warns at boot when its
  `timeout` is below `queue_wait + deadline + kill grace`.
- Counters are consistent across a fork: drive a known number of requests of each outcome, then assert
  `requests` and `killed_by` match.
- A caller that disconnects mid-request increments `cancelled` and frees its slot.

One boot-time control, which CI cannot substitute for because CI does not run on that host with that
image: the cell refuses to start when `kernel.yama.ptrace_scope` is `0`.

**One test is descriptive, not prescriptive, and must say so in its own name.** A sibling's
`/proc/<pid>/environ` *is* readable between workers, and so is its scratch, and a test that records this
is documenting a limitation we accept rather than a property we want. Name it so, or someone will one day
read a failure as a regression when it is a kernel improvement. Everything else in this list is
prescriptive.

### Proving the assertions are not vacuous

Every security control needs a test that observes the behaviour the control produces, not one that asserts the
control is written down. `unsetenv_others` is proved by setting a variable in the parent, running a tool,
and finding that the tool never saw it — and by asserting the premise, that the worker did inherit it, so
the test cannot pass because the variable was never set. Widening an input descriptor to read-write, skipping
the limit clamp, dropping an operation's argument allowlist, returning success without writing the output, and
answering `ok` when the worker was killed all get the same treatment.

A control with no behavioral test behind it is a comment.

**This was first built as a mutation harness, and that was the wrong shape.** A monkey-patch per control, each
re-running a whole suite to confirm the suite noticed. It cost five minutes, and every one of its thirty
mutations turned out to be caught by a behavioral test that already existed — the mutations proved nothing the
suites did not already prove. Worse, a mutation file that had gone stale against a rename crashed on load, and
the harness scored the crash as caught. It reported success for several commits while testing nothing. A
verification harness that can lie in the reassuring direction is worse than no harness.

**A control that nothing can currently trigger should say so where it lives, rather than be quietly counted as
covered.** Two in the supervisor are marked this way: the buffered read of a worker's reports, and the rescue
around a control answer. Neither is hard to test — each is untestable, because as the code stands nothing
reaches it. Each note says what would make it reachable and what breaks when it does, so a later reader can
tell defence in depth from dead code.

### The canary harness, withdrawn

An earlier draft of this section required a harness that booted a cell with the accessory's hardening,
planted **synthetic** canaries — an environment variable and a fake `/rails/config/master.key` — and
demonstrated a proof-of-concept exploit finding nothing worth having.

It was withdrawn before being built. The honest version needs a deliberately vulnerable operation
checked into the source tree for the exploit to come in through, and what the demonstration proves —
the container flags are on, and the environment holds nothing — is what `docker/smoke` and the
environment tests already verify directly. A rehearsal of verified properties was not worth a shipped
vulnerability.

## 11. Out of scope

**Directory-shaped work.** `ZipScriptRunner.archive_folder` archives a directory tree, and a descriptor
is not a tree. Not in scope for the first version. When it is wanted, the cheap route is to stream a tar
in over one input descriptor and write the archive to one output, which needs nothing new and makes an
archiver cell no different in shape from any other. The principled route, passing a directory descriptor
opened `O_DIRECTORY` and working relative to it with `openat`, gives no path to traverse but needs FFI,
since Ruby does not expose `openat`.


## Appendix A. Why descriptors rather than a shared volume

The obvious alternative is a directory mounted into both containers: the app writes an input file and
names it, the cell writes an output file and names it. It is simpler, and it has one real advantage this
design gives up. Recorded here because the reasoning is not obvious and will otherwise be relitigated.

**It removes a class of bug rather than a bug, and that is the deciding reason.** With a volume the app
must open a path the cell can write to. The cell creates that path as a symlink to
`/rails/config/master.key`, which resolves in the *app's* mount namespace; the app reads it and publishes
it as a public image variant. `O_NOFOLLOW` closes that, but only for the final component, so an
intermediate directory symlink still works, and closing that needs `openat2` with `RESOLVE_NO_SYMLINKS`,
which Ruby does not expose. Add a sticky exchange directory so the cell cannot unlink the app's files,
have the app pre-create both files, validate the descriptor with `fstat` for a regular file and an exact
size, and never list the directory. That is a checklist that must each be remembered forever, each item
failing silently. Descriptors have no such checklist, because there is no path.

This is not a hypothetical comparison. thimble's video role took the volume route — it had to, for a
reason given below — and then wrote down precisely this checklist: a token validated against
`\A[a-f0-9]{32}\z`, a path built server-side from one component, `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, an
`fstat` on the descriptor for a regular file and an exact size under a maximum, and then **the open
descriptor rather than the path handed to the tool.** Which is to say it arrived at descriptor
passing anyway, having paid for the volume first.

**Cross-request isolation is a smaller reason than it first appears, and the difference matters.** Under a
shared volume every worker can read every request's bytes in the directory, including requests not
currently running. Under descriptors only in-flight requests have bytes inside the cell. That narrower
window is the real gain.

What descriptors do *not* buy is isolation between concurrent workers, and it is worth being blunt because
the argument is tempting: the worker copies its input to scratch on a tmpfs that every worker shares, all
workers run as one uid in one mount namespace, and a sibling can reach both the directory and the open
descriptor through `/proc`. Unlinking does not close it either. The fixes need `CAP_SETUID` or
`CAP_SYS_ADMIN`, which `cap-drop ALL` removes. See "Worker isolation". So the honest claim is that
descriptors remove the naming attacks and the data at rest; fork-per-request removes cross-request
*memory* access; and cross-request *file* access inside one cell remains, bounded by concurrency and by
the cell holding one toolchain and no credentials.

**Nothing is left at rest.** A volume is persistent and outlives requests, so it holds user content
somewhere neither side owns, and a crashed worker leaves it there. The socket directory holds a socket
and no data.

**What descriptors do not buy, so nobody oversells them.** The bytes are copied to the cell's tmpfs
regardless, so the cell has full read and write on its own copy. The output is a file the app created
and the cell writes arbitrary bytes into it either way, so a compromised cell can return a malicious
image and the app will publish it. Descriptors protect *naming*. They do not protect or validate
content.

**The cost, accepted knowingly.** A bind mount crosses Docker Desktop's VM boundary and a descriptor
does not, so a volume-based design would let macOS developers run the real container with the real
hardening. Descriptors cost us that, which is why section 9 exists. Removing a whole class of naming bug
is worth more than development parity, because that class fails silently and each mitigation for it has to
be remembered forever.

**Where a volume wins, and it is not a corner case.** An input larger than the cell's tmpfs cannot be
posted in at all. thimble's video role hit this and switched: a 3GB blob will not spool onto a 512MB
tmpfs at any body limit, and `ffprobe` reads only a container header, so store-and-forward measured at
roughly 300× I/O amplification on its commonest call. Note carefully what this is *not* an argument
against — descriptor passing has no such problem, because the descriptor already refers to a file on the
application's own filesystem. The amplification comes from the **copy** an input performs when asked
for its path, not from the transport. So the fix is per-operation and stays inside this design: an
operation that can consume a descriptor directly never asks, and never pays. See section 4.

## Appendix B. What the overhead measures at

From a prototype of the transport and process model described here, benchmarked with `benchmark-ips`.
**On a laptop development machine**, so treat the direction and the rough magnitude as sound and the
precise multipliers as not. Variance on the fastest arm reached ±43%, on a loaded machine. Several runs at
different sampling lengths agreed with each other on the ratios.

Read this appendix for its two negative results rather than its table. The numbers are a laptop's; the
things that were ruled out are properties of the design.

Three arms, each producing a 256×256 PNG with `resize_to_fill`, which is a real inline-processed avatar
variant:

1. **In process**, exactly as Active Storage does it today.
2. **Native cell**, a server process on the same host over a Unix socket, which isolates the cost of the
   socket, the fork, and the tmpfs copy.
3. **Containerized cell**, with the hardening flags from section 2, which adds the container boundary on
   top.

| Source | In process | Native cell | Containerized cell |
| --- | --- | --- | --- |
| 640×640 JPEG, 12KB | 19.3 ms | 39.4 ms | 45.0 ms |
| 806×926 PNG, 339KB | 39.1 ms | 71.0 ms | 73.7 ms |
| 3224×3704 JPEG, 328KB | 72.3 ms | 108.2 ms | 121.7 ms |

Slower by 2.3×, 1.9×, and 1.7×.

**The libvips operation cache was ruled out as a confound.** The in-process arm repeats an identical
pipeline on an identical source and could in principle serve some of that from libvips' cache, while a
cell forks per request and always starts cold — which would inflate the whole comparison. Re-running
every arm with `Vips.cache_set_max 0` moved the in-process column by less than the error bars in all
three rows, and left the ratios at 2.2×, 1.7×, and 1.5×. The cache was not doing anything here. Worth
recording because it is the first thing a reader should suspect.

**The overhead is roughly fixed at 25 to 35 ms**, which is why the multiplier falls as the work grows.
Expect the ratio to look worst on the smallest thumbnails and to stop mattering on anything expensive.

**The container is not the cost.** Native and containerized are within noise on the two smaller sources
and about 12 ms apart on the largest.

**Nor is it the fork.** Measured directly — `fork`, `exit!`, and `wait` from a 58 MB three-thread parent
with libvips required and never evaluated — that is **2.8 ms**.

### Where the overhead actually goes

Instrumenting the worker's phases and comparing them against the client's round trip attributes it fully.
Per request, on the 806×926 PNG:

| Component | Cost |
| --- | --- |
| Connect, accept, dispatch, reap, and the client's file opens | 3.0 ms |
| `mktmpdir`, stage the input in, stage the output back | 0.85 ms |
| Four `setrlimit` calls | 0.07 ms |
| Write the response | 0.27 ms |
| The worker's first touch of inherited memory during `recvmsg` and parse | ~3 ms |
| **Copy-on-write faulting during the worker's first pipeline run** | **the rest** |

**The overhead is copy-on-write, measured rather than inferred.** The identical pipeline runs about 14 ms
slower in a freshly forked worker than in a long-lived process. Run it *twice* in the same child and the
second call matches a warm process, so it is one cost per process, not per call. Minor fault counts say what
it is: **7,920 faults on a child's first call against 1,564 warm**, about 25 MB of pages copied at roughly
1.7 µs each.

Four candidates were tested and eliminated, recorded so nobody re-runs them:

| Candidate | Verdict |
| --- | --- |
| The container | Within noise of the native cell on two of three sources. |
| The `fork` syscall | 2.8 ms of a 20–30 ms cost. |
| `RLIMIT_AS`, which the worker sets and the in-process arm does not | No effect. 8 GB, 2 GB, and unset are indistinguishable. |
| libvips thread pool startup per worker | Not it. The first-versus-second-call gap is *largest* at concurrency 1. |

### Two levers, and one of them is free

**The tax is proportional to the supervisor's resident heap.** Forking the same workload from a parent
inflated to 265 MB instead of 58 MB took faults from 8,947 to 25,926 and added about 52 ms per request. So
the cheapest optimisation is the counter-intuitive one: **keep the supervisor small, and treat `before_fork`
as having a per-request price.** The instinct is to preload generously so workers start fast. It is backwards
here — every megabyte the supervisor holds is partly copied by every worker for the rest of the deployment.
`before_fork` must still `require`, because of the fork hazard in section 8 item 1, so the resolution is to
require only what that cell's own operations need. That is a third argument for one cell per toolchain, and a
measured reason for `hotcell-server` not to depend on `activesupport`.

Do not spend effort making the container cheaper. There is nothing there to win.

**Reusing a worker recovers the rest, and the prize is a third of the request.** Measured per position in
one worker's life:

| Position in a reused worker | Time | Minor faults |
| --- | --- | --- |
| request 1 | 68.5 ms | 7,907 |
| request 2 | 50.7 ms | 3,590 |
| request 3 | 38.3 ms | 1,875 |
| request 4 | 41.9 ms | 1,786 |
| request 5 | 40.8 ms | 1,220 |
| *a fresh worker every time* | *71.2 ms* | *8,004* |

Paid once and never again, effectively decayed by the third request. A fresh worker matches a reused worker's
*first* request on both time and faults, which is the check that both arms measure the same thing. Over 70
transforms of identical total work, timed by the parent so `fork` and reap are included: **3,380 ms reused
against 5,289 ms fresh — 27.3 ms saved per transform, 36%.**

That is larger than the phase table above implies, for two reasons worth stating: the phase numbers exclude
fork and reap, and a reused worker converges to about 40 ms rather than the 46–54 ms a long-lived benchmark
process shows. So the trade is worth about a third of the request. It is the `max_requests_per_worker` setting in section 4, it
costs invariant 8 above `1`, and it amortizes fast enough that a high value buys nothing. Shrink the
supervisor first, because that lever costs no isolation at all.

**Synthetic pre-warming is not a free alternative to max_requests_per_worker.** Tested, because it would have been the ideal
answer: running a synthetic 64×64 pipeline in the worker before the real transform moved the real
transform's faults from 7,885 only to 6,184, against a warm floor of about 3,300 — roughly a quarter of the
excess. Most of the cost is proportional to the real image's own work, not to shared code paths a synthetic
image would touch.

Budget the fixed cost against inline processing. A variant generated during an upload request, as Active
Storage's `process: :immediately` does, adds this overhead to that request. One variant is around 34 ms;
an attachment generating two immediate variants is around 70 ms. Whether that is acceptable is a product
decision, and it is the main reason to measure this early on real hardware.
