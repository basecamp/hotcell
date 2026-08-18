# 0003. Remove the persistent slot home

- Status: Accepted
- Date: 2026-08-17
- Deciders: Mike Dalessio
- Supersedes: [ADR 0002](0002-keep-the-warm-slot-home.md)

## Context

[ADR 0002](0002-keep-the-warm-slot-home.md) kept the slot's `home` directory alive across worker
processes, so that a tool with an expensive per-user profile would find a warm one. It accepted a
cross-request write channel in exchange, on the reasoning that the exposure is a write rather than a
read and that nothing sensitive belongs in a tool's working home.

A pre-release security review shows that framing is wrong. Secrecy was never the property at risk. The
files a tool reads from `$HOME` are configuration, and for the toolchains a cell carries, configuration
is executable.

### What was measured

Against ImageMagick 7.1.2:

- `$HOME/.config/ImageMagick/` is the last entry in ImageMagick's configuration search path, confirmed
  with `-debug configure`.
- `delegates.xml` is a table of shell command lines, one per format ImageMagick does not decode itself.
  A planted file registering a format the system does not define runs its command line.
- `policy.xml` is the deny list a hardened image ships. A planted user `policy.xml` re-grants a coder
  that the system policy denied. The last policy read wins.
- A system `<policy domain="delegate" rights="none" pattern="*"/>` does hold: it blocks a planted
  delegate, and a planted policy cannot grant it back. Adding
  `<policy domain="policy" rights="none" pattern="*"/>` does not extend that protection to the coder
  domain.
- Neither `XDG_CONFIG_HOME` nor `MAGICK_CONFIGURE_PATH` suppresses the per-user directory. Only a clean
  `HOME` does.

So an input that achieves code execution in one worker writes one configuration file, and every later
worker on that slot runs a tool the attacker has reconfigured. That survives worker exit and it survives
`max_requests_per_worker: 1`, which is the setting the README and `docs/DESIGN.md` present as the bound
on a compromise. Fork per request buys memory isolation, and this payload is on disk.

ImageMagick is the tool that was measured, not the extent of the problem. fontconfig, GLib, and ffmpeg
all read configuration from `$HOME`. Closing this tool by tool is a blocklist against every toolchain a
cell may carry, written by us and never finished.

### What ADR 0002 named as its fallback

Option 3: a per-operation choice between a warm home and a fresh one. That is not what this record takes.
Two facts settle it.

Nothing ships that uses the warm home. `ENV["HOME"] = slot.home` has two readers in the tree,
`Operation#tool_environment` and the test operations. None of the eight Active Storage operations depends
on it. The warm home serves a LibreOffice operation that does not exist.

The cost it was trading against was never measured. ADR 0002 says so itself, and asks for a LibreOffice
profile cold start number before the fallback is chosen. That number still does not exist, so a
per-operation switch would be a permanent piece of surface added for an unmeasured benefit to an
unwritten operation.

## Options considered

1. Keep the warm home and harden ImageMagick in the image. Closes the command-execution route for one
   tool. Leaves the coder policy defeatable, leaves every other tool's configuration untouched, and
   leaves the general claim about `max_requests_per_worker: 1` false.
2. Take ADR 0002's own fallback, a per-operation warm-or-fresh home. Adds a declaration and a second
   cleanup path now, for an operation nobody has written, against a cost nobody has measured.
3. Remove the persistent home. Every request gets a fresh `HOME` that is removed with its scratch.

## Decision

Take option 3. Remove the persistent slot home. A slot holds one directory per request, which is that
request's `$HOME` and also where its inputs and outputs are staged. It is created when the request starts
and removed before the caller hears the answer, so no file a tool writes outlives the request that wrote
it.

One directory rather than two. `home` and `scratch` were siblings with different lifetimes, and once the
home stops surviving they have the same lifetime and the same owner. Staging used to create its directory
on demand, which kept a descriptor-only operation from paying for one; `$HOME` has to exist for every
request either way, so that laziness now buys nothing and goes with it.

If an operation is later shown to need a warm profile, that operation owns the optimization. Reintroducing
per-slot or per-operation persistence needs a superseding record and a measured cold start, not an
appeal to this one.

The ImageMagick delegate deny is worth adding to the image template on its own merits. It is a separate,
additive change and it is not what this record rests on.

## Consequences

- A compromise is bounded to the request that achieved it. The claim the README and `docs/DESIGN.md`
  make about `max_requests_per_worker: 1` becomes true in general rather than true for the tools whose
  configuration we happened to enumerate.
- `Slot` holds one path instead of two, creates nothing at boot, and has one cleanup path rather than
  two. `make_scratch` and the lazy creation behind it are gone.
- A tool with an expensive per-user profile pays its cold start on every request. Nothing shipped has
  one, so this cost is not paid today. Whoever writes the first operation that has one pays it, measures
  it, and brings the number to a superseding record.
- `docs/DESIGN.md`'s "Worker isolation" section gains the property rather than losing a residual: nothing
  on disk carries from one request to the next. The file residual between *concurrent* workers is
  unaffected and stays.
- [ADR 0001](0001-reuse-workers-across-requests.md) says under "A justification that turned out to be
  false" that a file written into a slot's home is still readable by the next request on that slot. That
  was true when it was written and is not true now. Records are not edited, so it stands as written and
  this one is where the change lives.
- ADR 0002 is superseded rather than edited, and the index records both.
