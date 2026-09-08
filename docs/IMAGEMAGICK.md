# ImageMagick's resource limits in a cell

ImageMagick bounds itself through the `MAGICK_*_LIMIT` environment variables and a `policy.xml`. The
scaffold's `Dockerfile` installs no ImageMagick and sets none of them; an image that installs ImageMagick
must set them. Part one describes the variables and how they interact with a cell. Part two is how to
set them.

[docs/DEPLOYMENT.md](DEPLOYMENT.md) covers the container flags and cell settings that part two starts
from: `memory`, `concurrency`, `file_size`, and "Where scratch lives".

- [Part one: what the variables do](#part-one-what-the-variables-do)
  * [The variables](#the-variables)
  * [How they interact in a cell](#how-they-interact-in-a-cell)
- [Part two: how to set them](#part-two-how-to-set-them)
  * [The formulas](#the-formulas)
  * [A worked example](#a-worked-example)
  * [Checking a built image](#checking-a-built-image)
  * [When to recompute](#when-to-recompute)

## Part one: what the variables do

### The variables

ImageMagick decodes every frame into a *pixel cache*, an uncompressed `width × height × bytes per pixel`
array, and the limits decide where each cache lives. ImageMagick's
[resources page](https://imagemagick.org/script/resources.php) is the reference; this table is the summary.

| Variable | Unit | Bounds |
| --- | --- | --- |
| `MAGICK_MEMORY_LIMIT` | bytes | Caches on the heap, all frames together. |
| `MAGICK_MAP_LIMIT` | bytes | Caches that missed the heap and are memory-mapped files. |
| `MAGICK_DISK_LIMIT` | bytes | Cache files on disk, mapped or not, all frames together. Past it the operation fails with `cache resources exhausted`. |
| `MAGICK_AREA_LIMIT` | pixels | The largest single frame allowed on the heap. Over it, the frame goes to a file even when the heap would hold it. It never refuses a frame. |
| `MAGICK_THREAD_LIMIT` | threads | The OpenMP team ImageMagick asks for. |
| `MAGICK_TMPDIR` | path | Where the cache files go. Read before `TMPDIR`. |

Bytes per pixel come from the build: 8 on ImageMagick 6 Q16 without HDRI, which is Ubuntu's
`imagemagick-6.q16` (four 16-bit channels), 10 with an index or black channel; an HDRI build stores
floats and doubles both. A 4096 × 4096 image is 128MiB before anything is done to it, a layered PSD holds one cache
per layer at once, and a transform holds source and result at once.

The three byte limits are a chain: heap, then mapped file, then plain file, and a cache takes one tier
whole. Both file tiers count against `disk`. So a single frame is readable only if it fits `memory` or
`disk` on its own. A multi-frame file needs every frame placed in turn, each in the first tier with room
left, so its frames can total at most `memory` plus `disk`, and less when they pack badly: a frame that
misses the heap's remainder must fit the disk's remainder on its own.

Each limit has three sources. The build's default (most of the host's RAM, unbounded disk) is replaced
by the environment, upward or downward; `policy.xml` is a ceiling on both, which the environment can
lower and never raise. They are read once: when the `magick` process starts, or at ImageMagick's first
use inside a process that loaded the library. Limits are per process. `identify -list resource` prints
the result.

### How they interact in a cell

**The environment reaches both ImageMagicks.** ImageMagick runs in a cell two ways. In-process, when
libvips delegates PSD, BMP and ICO to `magickload`; the library reads the worker's environment. As a
child, when mini_magick spawns `identify` or `magick` for `analyzers.image.magick` and
`transformers.image.magick`. mini_magick runs with `restricted_env`, which passes the child only `HOME`,
`PATH`, `LANG` and `MiniMagick.cli_env`, so `MagickOperation` rebuilds `cli_env` for every request from
the worker's `MAGICK_*_LIMIT`, `TMPDIR` and `MAGICK_TMPDIR`.

**`MAGICK_TMPDIR` is the gem's.** `Operation#initialize` maps it from the request's `TMPDIR`, so in-process
cache files land in the request's directory and are removed with it. Do not set it in the image, and do
not set a `temporary-path` policy, which overrides it.

**Every limit divides by `concurrency`.** The limits are per process, and the cell runs `concurrency`
processes against one `/tmp` and one cgroup.

**`file_size` cannot do the disk limit's job.** `file_size` is `RLIMIT_FSIZE`, a limit on each file. A
layered PSD writes one cache file per layer, and twenty 40MiB caches total 800MiB with no file near a
48MiB `file_size`. Only `MAGICK_DISK_LIMIT` bounds the sum. Where the two meet, the smaller fires
first, as an `fsize` kill or as `cache resources exhausted`; both are permanent verdicts on the file.

**A disk limit larger than the scratch is not a limit.** The scratch fills first. A full scratch fails
every request on the cell that needs scratch, and a write that fails inside libvips is a `Vips::Error`,
which the gem declares `unreadable`: permanent, and recorded against a customer's file. On 2026-09-01 one
PSD under a `10GiB` disk limit filled a 4G scratch on six hosts and convicted 3,393 blobs. Under a
disk limit sized to a worker's share, the same file is `unreadable` on its own first request, in
milliseconds, with the scratch empty afterwards.

**For `magickload`, the cache files are the spill.** libvips writes a decode above `VIPS_DISC_THRESHOLD`
to `TMPDIR`; when the decode is ImageMagick's, its cache files stand in for that temporary rather than
adding to it. So the disk limit and the transformer's `file_size` describe the same bytes.

**A heap cache is charged to `RLIMIT_DATA` and to the cgroup.** It is private anonymous memory, so the
operation's `memory` counts it and so does the container's. `MAGICK_MEMORY_LIMIT` plus the worker's own
footprint must sit under a worker's share of the cgroup and under the `memory` of every operation that
can reach ImageMagick. Above either, the process dies (`killed`, or libgomp's `exit(1)` on a thread it
cannot create) instead of refusing the frame, and a death is transient: the request is retried against
a limit that fails it again.

**`MAGICK_AREA_LIMIT` adds nothing.** It moves the heap-or-file line in pixels; `memory` already draws it
in bytes. Set below `memory`, it sends frames to scratch the heap could have held.

**`MAGICK_THREAD_LIMIT` raises the OpenMP count itself**, and `OMP_THREAD_LIMIT` caps it. See
[Bound the OpenMP thread pools](DEPLOYMENT.md#bound-the-openmp-thread-pools).

## Part two: how to set them

### The formulas

Every "MiB" is `1024²` bytes, as `config.rb` writes it. Work each operation that can reach ImageMagick
separately and set the image to the smallest result.

**`MAGICK_DISK_LIMIT`**

    scratch ÷ concurrency − what else the operation writes on scratch

Scratch is the tmpfs `size=` or the host filesystem's usable size as `df` reports it, which on an ext4
made with default options is 5% under the nominal size; a named volume has no size to divide. The
subtraction is the operation's own files: its output, and its input if it stages one. The shipped image
operations read their input through the descriptor and stage nothing; a transformer writes its output on
scratch before copying it out. The result must be zero or more. Below zero, enlarge the scratch or lower
`file_size` or `concurrency`; ImageMagick reads a negative value as a huge one.

**`MAGICK_MAP_LIMIT`** = `MAGICK_DISK_LIMIT`. The mapped caches are the same files on the same scratch.

**`MAGICK_MEMORY_LIMIT`**

    (memory − tmpfs) ÷ concurrency − a worker's own footprint, rounded down

On a disk-backed scratch there is no tmpfs term. The footprint is the worker's resident size with the
gems loaded plus the child it may spawn; measure it as `VmRSS` in `/proc/<pid>/status` after a request.
Round down to leave the worker something for what the limit does not count. Then check the result plus
the footprint against each reaching operation's `memory`.

**`MAGICK_AREA_LIMIT`**: unset. **`MAGICK_THREAD_LIMIT`**: `OMP_NUM_THREADS`, or unset.
**`MAGICK_TMPDIR`**: unset.

**`policy.xml`**: the same `disk` value.

### A worked example

A production cell serving image transforms and analysis for a Rails application.

**The volume mount.** `/tmp` is a bind mount of a 4G loopback ext4 file on the host, mounted
`nosuid,nodev,noexec` and chowned to the cell's uid by the host's configuration management:

```yaml
accessories:
  active_storage:
    volumes:
      - hotcell-sockets:/run/hotcell/cell
      - /var/lib/hotcell-scratch:/tmp
    options:
      cpus: 2
      memory: 2g
      memory-swap: 2g
```

It is disk rather than the scaffold's tmpfs because a tmpfs is RAM charged to the cgroup: every byte of
scratch is a byte the workers cannot have. It is a dedicated filesystem rather than a named volume or a
plain directory because the filesystem's size is the cap and its mount flags reach the container; Docker
can set neither on a bind mount. [docs/DEPLOYMENT.md](DEPLOYMENT.md#a-host-mounted-filesystem) has the recipe.

**The constraints.**

| Input | Value | From |
| --- | --- | --- |
| scratch | 4096MiB | the loopback filesystem, taken as fully usable; see the note under "Disk" |
| container `memory` | 2048MiB | `memory: 2g`, no tmpfs term |
| `concurrency` | 4 | `config.rb`, twice `cpus` |
| cell ceiling | `memory: 1536MB`, `file_size: 768MB` | `config.rb`; an operation's own limits are clamped to these |
| `transformers.image.vips` | `memory: 1280MB`, `file_size: 768MB` | `file_size` raised in the application's operations file |
| `analyzers.image.vips` | `memory: 1024MB`, `file_size: 48MB` | gem defaults |
| `analyzers.image.magick` | `memory: 1024MB`, `file_size: 48MB` | gem defaults |
| `OMP_NUM_THREADS` | 2 | the image, matching `cpus` |
| ImageMagick | 6 Q16 | 8 bytes per pixel |

ImageMagick is reached three ways: the vips transformer and analyzer through `magickload`, and the
magick analyzer through an `identify` child. All three read their input through the descriptor. The
transformer writes its output on scratch; the analyzers write nothing.

**Disk.** Nothing is staged, so the only thing to hold back is the transformer's output, measured at a
peak of 256MiB per worker:

    MAGICK_DISK_LIMIT = 4096 ÷ 4 − 256 = 768MiB
    MAGICK_MAP_LIMIT  = 768MiB

It equals the transformer's `file_size` because that was sized by the same arithmetic, the
application's test holds it, and the cell ceiling allows it. Four workers spilling 768MiB and writing
256MiB beside it fill 4096MiB exactly, so the arithmetic assumes the whole 4G is usable: a filesystem made
with `mkfs.ext4 -m 0`, or an image larger than 4G. On a 4G ext4 with the default 5% root reserve, `df`
shows about 3891MiB usable and the same arithmetic gives 716MiB. Check `df` on a cell host before taking
the number. On the analyzer, whose `file_size` is 48MB, a cache file over that takes the `fsize` kill
first.

**Memory.**

    per worker          = 2048 ÷ 4 = 512MiB
    footprint           = 70MiB resident + 12MiB for an `identify` child = 82MiB
    ceiling             = 512 − 82 = 430MiB
    MAGICK_MEMORY_LIMIT = 384MiB, the round number under it

Four workers at the limit are `4 × (384 + 82) = 1864MiB` under the 2048MiB cgroup. `384 + 82 = 466MiB`
sits under the analyzers' 1024MB and the transformer's 1280MB.

**Together.**

    MAGICK_MEMORY_LIMIT = 384MiB
    MAGICK_MAP_LIMIT    = 768MiB
    MAGICK_DISK_LIMIT   = 768MiB
    MAGICK_THREAD_LIMIT = 2
    MAGICK_AREA_LIMIT   = unset

and `disk` at 768MiB in `policy.xml`.

**What that buys**, at 8 bytes a pixel and summed over every cache open at once:

| Limit | Pixels | For instance |
| --- | --- | --- |
| 384MiB heap | 50.3 million | 8192 × 6144 |
| 768MiB disk | 100.7 million | 16384 × 6144 |
| both, multi-frame | up to 151 million | a 19-layer PSD at 2740 × 2740: 6 layers on the heap, 13 on disk |

A same-size transform holds source and result, so it decodes half a tier. A larger file is `unreadable`
on its first request, and the scratch is empty afterwards. The limits the image had inherited from the
application were `1GiB`, `5GiB` and `10GiB`: memory twice a worker's share of the cgroup, disk two and a
half times the scratch.

### Checking a built image

Inside the image, as the cell's user, `identify -list resource` prints the effective limits: `Disk`
should be the number computed, `Area` unbounded. `identify -list policy` shows what `policy.xml` set,
and that `temporary-path` is absent.

To watch the tiers:

```
MAGICK_MEMORY_LIMIT=64MiB magick -size 4000x4000 xc:red -debug cache info:
```

On ImageMagick 6 the command is `convert`.

The cache opens as a file under `MAGICK_TMPDIR`. Raise the size until it passes the disk limit too and
the command fails with `cache resources exhausted`.

End to end, send a layered file larger than the disk limit through the cell: the answer is
`unreadable`, and the scratch root is empty afterwards. A cache file left behind means the spill went
to `/tmp` rather than the request's directory.

### When to recompute

When any input moves: the scratch's size, the container's `memory`, `concurrency`, an operation's
`file_size` or `memory`, the worker footprint, which operations reach ImageMagick, or the ImageMagick
build's bytes per pixel. Keep the formulas next to the values in the `Dockerfile`.
