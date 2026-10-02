---
type: Reference
title: "ImageMagick"
description: "ImageMagick's MAGICK_* resource limits, how they interact with a cell, and the formulas to set them."
sources:
  - activestorage-hotcell-server/lib/active_storage/hot_cell/server/magick_operation.rb
  - activestorage-hotcell-server/lib/active_storage/hot_cell/server/operation.rb
---

# ImageMagick

This page describes ImageMagick's resource limits and how to set them in a cell. ImageMagick bounds itself
through the `MAGICK_*_LIMIT` environment variables and a `policy.xml`. The installed `Dockerfile` installs
no ImageMagick and sets none of them. An image that installs ImageMagick must set them.

The formulas start from the container flags and cell settings in [Container](container.md),
[Cell settings](cell-settings.md), and [Scratch](scratch.md): `memory`, `concurrency`, `file_size`, and
the scratch's size.

## Variables

ImageMagick decodes every frame into a *pixel cache*, an uncompressed `width × height × bytes per pixel`
array, and the limits decide where each cache lives. ImageMagick's
[resources page](https://imagemagick.org/script/resources.php) is the reference. This table summarizes it.

| Variable | Unit | Bounds |
| --- | --- | --- |
| `MAGICK_MEMORY_LIMIT` | bytes | Caches on the heap, all frames together. |
| `MAGICK_MAP_LIMIT` | bytes | Caches that missed the heap and are memory-mapped files. |
| `MAGICK_DISK_LIMIT` | bytes | Cache files on disk, mapped or not, all frames together. Past it, the operation fails with `cache resources exhausted`. |
| `MAGICK_AREA_LIMIT` | pixels | The largest single frame allowed on the heap. A larger frame goes to a file even when the heap would hold it. It never refuses a frame. |
| `MAGICK_THREAD_LIMIT` | threads | The OpenMP team that ImageMagick asks for. |
| `MAGICK_TMPDIR` | path | Where the cache files go. Read before `TMPDIR`. |

Bytes per pixel come from the build. ImageMagick 6 Q16 without HDRI, which is Ubuntu's
`imagemagick-6.q16` (four 16-bit channels), uses 8, or 10 with an index or black channel. An HDRI build
stores floats and doubles both. A 4096 × 4096 image is 128MiB before anything is done to it, a layered PSD
holds one cache for each layer at once, and a transform holds source and result at once.

The three byte limits are a chain: heap, then mapped file, then plain file, and a cache takes one tier
whole. Both file tiers count against `disk`. So a single frame is readable only if it fits `memory` or
`disk` on its own. A multi-frame file needs every frame placed in turn, each in the first tier with room
left, so its frames can total at most `memory` plus `disk`, and less when they pack badly: a frame that
misses the heap's remainder must fit the disk's remainder on its own.

Each limit has three sources:

1. The build's default: most of the host's RAM, and unbounded disk.
2. The environment, which replaces the default, upward or downward.
3. `policy.xml`, a ceiling on both. The environment can lower it and can never raise it.

ImageMagick reads the limits once: when the `magick` process starts, or at ImageMagick's first use inside a
process that loaded the library. Limits apply to each process. `identify -list resource` prints the
result.

## How the limits interact in a cell

**The environment reaches both ways that ImageMagick runs in a cell.**

- In-process, when libvips delegates PSD, BMP, and ICO to `magickload`. The library reads the worker's
  environment.
- As a child, when mini_magick spawns `identify` or `magick` for `analyzers.image.magick` and
  `transformers.image.magick`. mini_magick runs with `restricted_env`, which passes the child only `HOME`,
  `PATH`, `LANG`, and `MiniMagick.cli_env`. So `MagickOperation` rebuilds `cli_env` for every request from
  the worker's `MAGICK_*_LIMIT`, `TMPDIR`, and `MAGICK_TMPDIR`.

**The gem sets `MAGICK_TMPDIR`.** `Operation#initialize` sets it from the request's `TMPDIR`, so in-process
cache files land in the request's directory and are removed with it. Don't set it in the image, and don't
set a `temporary-path` policy, which overrides it.

**Every limit divides by `concurrency`.** The limits apply to each process, and the cell runs
`concurrency` processes against one `/tmp` and one cgroup.

**`file_size` can't do the disk limit's job.** `file_size` is `RLIMIT_FSIZE`, a limit on each file. A
layered PSD writes one cache file for each layer, and twenty 40MiB caches total 800MiB with no file near a
48MiB `file_size`. Only `MAGICK_DISK_LIMIT` bounds the sum. Where the two meet, the smaller fires first, as
an `fsize` kill or as `cache resources exhausted`. Both are permanent verdicts on the file.

**A disk limit larger than the scratch isn't a limit.** The scratch fills first. A full scratch fails every
request on the cell that needs scratch, and a write that fails inside libvips is a `Vips::Error`, which the
gem declares `unreadable`: permanent, and recorded against a customer's file. On 2026-09-01, one PSD under
a `10GiB` disk limit filled a 4G scratch on six hosts and convicted 3,393 blobs. Under a disk limit sized
to a worker's share, the same file is `unreadable` on its own first request, in milliseconds, with the
scratch empty afterward.

**For `magickload`, the cache files are the spill.** libvips writes a decode above `VIPS_DISC_THRESHOLD` to
`TMPDIR`. When the decode is ImageMagick's, its cache files take the place of that temporary file rather
than adding to it. So the disk limit and the transformer's `file_size` describe the same bytes.

**A heap cache is charged to `RLIMIT_DATA` and to the cgroup.** It's private anonymous memory, so the
operation's `memory` counts it, and so does the container's. `MAGICK_MEMORY_LIMIT` plus the worker's own
footprint must be under a worker's share of the cgroup and under the `memory` of every operation that can
reach ImageMagick. Above either, the process dies (`killed`, or libgomp's `exit(1)` on a thread that it
can't create) instead of refusing the frame. A death is transient, so the request is retried against a
limit that fails it again.

**`MAGICK_AREA_LIMIT` adds nothing.** It moves the heap-or-file line in pixels, and `memory` already draws
it in bytes. Set below `memory`, it sends frames to scratch that the heap could have held.

**`MAGICK_THREAD_LIMIT` raises the OpenMP count itself**, and `OMP_THREAD_LIMIT` caps it. See
[Bound the OpenMP thread pools](container.md#bound-the-openmp-thread-pools).

## Set the limits

### Formulas

Every "MiB" is `1024²` bytes, as `config.rb` writes it. Work out each operation that can reach ImageMagick
separately, and set the image to the smallest result.

**`MAGICK_DISK_LIMIT`**

    scratch ÷ concurrency − what else the operation writes on scratch

- Scratch is the tmpfs `size=`, or the host filesystem's usable size as `df` reports it, which on an ext4
  made with default options is 5% under the nominal size. A named volume has no size to divide.
- The subtraction is the operation's own files: its output, and its input if it stages one. The shipped
  image operations read their input through the descriptor and stage nothing. A transformer writes its
  output on scratch before copying it out.
- The result must be zero or more. Below zero, enlarge the scratch or lower `file_size` or `concurrency`.
  ImageMagick reads a negative value as a huge one.

**`MAGICK_MAP_LIMIT`** = `MAGICK_DISK_LIMIT`. The mapped caches are the same files on the same scratch.

**`MAGICK_MEMORY_LIMIT`**

    (memory − tmpfs) ÷ concurrency − a worker's own footprint, rounded down

- On a disk-backed scratch, there's no tmpfs term.
- The footprint is the worker's resident size with the gems loaded, plus the child that it can spawn.
  Measure it as `VmRSS` in `/proc/<pid>/status` after a request.
- Round down to leave the worker room for what the limit doesn't count.
- Check the result plus the footprint against the `memory` of each operation that reaches ImageMagick.

**`MAGICK_AREA_LIMIT`**: unset.

**`MAGICK_THREAD_LIMIT`**: `OMP_NUM_THREADS`, or unset.

**`MAGICK_TMPDIR`**: unset.

**`policy.xml`**: the same `disk` value as `MAGICK_DISK_LIMIT`.

### Worked example

This example is a production cell that serves image transforms and analysis for a Rails application.

**The volume mount.** `/tmp` is a bind mount of a loopback ext4 image on the host. The image is sized so
that `df` reports 4096MiB available when the mount is empty. The host's configuration management mounts it
`nosuid,nodev,noexec` and chowns it to the cell's uid:

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

Scratch is on disk rather than on the installed tmpfs, because a tmpfs is RAM charged to the cgroup: every
byte of scratch is a byte that the workers can't have. It's a dedicated filesystem rather than a named
volume or a plain directory, because the filesystem's size is the cap and its mount flags reach the
container. Docker can set neither on a bind mount. [Host-mounted filesystem](scratch.md#host-mounted-filesystem) has the recipe.

**The constraints.**

| Input | Value | From |
| --- | --- | --- |
| scratch | 4096MiB | `df --output=avail` on the empty loopback filesystem |
| container `memory` | 2048MiB | `memory: 2g`, no tmpfs term |
| `concurrency` | 4 | `config.rb`, twice `cpus` |
| cell ceiling | `memory: 1536MB`, `file_size: 768MB` | `config.rb`. An operation's own limits are clamped to these. |
| `transformers.image.vips` | `memory: 1280MB`, `file_size: 768MB` | `file_size` raised in the application's operations file |
| `analyzers.image.vips` | `memory: 1024MB`, `file_size: 48MB` | gem defaults |
| `analyzers.image.magick` | `memory: 1024MB`, `file_size: 48MB` | gem defaults |
| `OMP_NUM_THREADS` | 2 | the image, matching `cpus` |
| ImageMagick | 6 Q16 | 8 bytes per pixel |

Three operations reach ImageMagick: the vips transformer and analyzer through `magickload`, and the
magick analyzer through an `identify` child. All three read their input through the descriptor. The
transformer writes its output on scratch, and the analyzers write nothing.

**Disk.** Nothing is staged, so the only thing to hold back is the transformer's output, measured at a
peak of 256MiB per worker:

    MAGICK_DISK_LIMIT = 4096 ÷ 4 − 256 = 768MiB
    MAGICK_MAP_LIMIT  = 768MiB

This equals the transformer's `file_size`, because the same arithmetic sized it, the application's test
holds it, and the cell ceiling allows it. Four workers that spill 768MiB and write 256MiB beside it fill
the 4096MiB exactly.

That's why the scratch input is what `df` reports available, not the image's size: ext4's metadata and
its default 5% root reserve take part of the image, so a 4G image reports under 3891MiB, for which the
same arithmetic gives 716MiB. Size the image above what the arithmetic needs, and take the number from
`df` on a cell host.

On the analyzer, whose `file_size` is 48MB, a cache file over 48MB takes the `fsize` kill first.

**Memory.**

    per worker          = 2048 ÷ 4 = 512MiB
    footprint           = 70MiB resident + 12MiB for an `identify` child = 82MiB
    ceiling             = 512 − 82 = 430MiB
    MAGICK_MEMORY_LIMIT = 384MiB, the round number under it

Four workers at the limit use `4 × (384 + 82) = 1864MiB`, under the 2048MiB cgroup. `384 + 82 = 466MiB`
is under the analyzers' 1024MB and the transformer's 1280MB.

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
on its first request, and the scratch is empty afterward. The limits that the image had inherited from
the application were `1GiB`, `5GiB`, and `10GiB`: memory twice a worker's share of the cgroup, and disk two
and a half times the scratch.

### Check a built image

Inside the image, as the cell's user, run `identify -list resource` to print the effective limits. `Disk`
must be the number that you computed, and `Area` must be unbounded. Run `identify -list policy` to see what
`policy.xml` set, and check that `temporary-path` is absent.

To watch the tiers, run the following:

```
MAGICK_MEMORY_LIMIT=64MiB magick -size 4000x4000 xc:red -debug cache info:
```

On ImageMagick 6, the command is `convert`.

The cache opens as a file under `MAGICK_TMPDIR`. Raise the size until it passes the disk limit too, and
the command fails with `cache resources exhausted`.

To check end to end, send a layered file larger than the disk limit through the cell. The answer must be
`unreadable`, and the scratch root must be empty afterward. A cache file left behind means that the spill
went to `/tmp` rather than to the request's directory.

### When to recompute

Recompute the limits when any input changes:

- The scratch's size.
- The container's `memory`.
- `concurrency`.
- An operation's `file_size` or `memory`.
- The worker footprint.
- Which operations reach ImageMagick.
- The ImageMagick build's bytes per pixel.

Keep the formulas next to the values in the `Dockerfile`.
