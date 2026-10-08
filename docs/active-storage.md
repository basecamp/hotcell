---
type: Reference
title: "Active Storage operations"
order: 12
description: "The Active Storage client classes, the cell operations that serve them, how their failures are retried, and the limits each declares."
sources:
  - activestorage-hotcell-client/lib
  - activestorage-hotcell-server/lib
---

# Active Storage operations

This page describes the `activestorage-hotcell-client` and `activestorage-hotcell-server` gems, which run
Active Storage's variants, analysis, and previews in a cell. For a walkthrough, see
[Using the Active Storage operations](../README.md#using-the-active-storage-operations) in the README.

The Active Storage gems need Rails 8.2, which is unreleased. Rails can swap out variant processing only
from [rails/rails#58384](https://github.com/rails/rails/pull/58384)
([`5ea765e5`](https://github.com/rails/rails/commit/5ea765e5b00085a22f5cbe863c0d2ac765428242)) onward. The
`hotcell-*` gems themselves don't require Rails.

## Classes

For every class that you name in `config.active_storage`, the cell must load the matching operation, and
the cell's image must install the underlying library or tool.

| Application class, in `ActiveStorage::HotCell::Client` | Cell operation file, in `active_storage/hot_cell/server` | Routing name | Needs |
| --- | --- | --- | --- |
| `Transformers::Image::Vips` | `transformers/image/vips` | `active_storage.transformers.image.vips` | libvips |
| `Transformers::Image::Magick` | `transformers/image/magick` | `active_storage.transformers.image.magick` | ImageMagick |
| `Analyzers::Image::Vips` | `analyzers/image/vips` | `active_storage.analyzers.image.vips` | libvips |
| `Analyzers::Image::Magick` | `analyzers/image/magick` | `active_storage.analyzers.image.magick` | ImageMagick |
| `Analyzers::Video::FFprobe`, `Analyzers::Audio::FFprobe` | `analyzers/media/ffprobe` | `active_storage.analyzers.media.ffprobe` | `ffprobe` |
| `Previewers::Pdf::Mutool` | `previewers/pdf/mutool` | `active_storage.previewers.pdf.mutool` | `mutool` |
| `Previewers::Pdf::Poppler` | `previewers/pdf/poppler` | `active_storage.previewers.pdf.poppler` | `pdftoppm` |
| `Previewers::Video::FFmpeg` | `previewers/video/ffmpeg` | `active_storage.previewers.video.ffmpeg` | `ffmpeg` |

The `Magick` classes replace Rails' `variant_processor = :magick`. If your application uses ImageMagick
today, use `Magick` wherever the README uses `Vips`, and `magick` wherever it uses `vips`.

If an image that installs ImageMagick serves any of these operations, set ImageMagick's own limits. libvips
also delegates PSD, BMP, and ICO to ImageMagick. See [ImageMagick](imagemagick.md).

### Mix with Rails' own classes

Rails' own classes mix freely with these in the `analyzers` and `previewers` arrays, so you can move only
some work into a cell:

```ruby
# PDF previews handled by Hot Cell, video previews still in the application
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::Previewer::VideoPreviewer ]
```

### Route an operation to another cell

Every client class talks to the cell registered as `active_storage` by default. A cell carries one
toolchain by design, so to send one operation to a different cell, name that cell on the operation's
client class, for example in an initializer:

```ruby
ActiveStorage::HotCell::Client::Operations::Previewers::Video::Ffmpeg.hotcell "video"
```

Register that cell too. See [Client API](client-api.md#register-a-cell).

## Remove packages from the application image

After a file type's processing moves into the cell, remove its packages, such as libvips, from the
application image. That removal is the security improvement.

**Caution:** Remove a package only after the cell handles that file type. Rails' own previewers and
analyzers look for their tool in `accept?`: `MuPDFPreviewer.accept?` calls `mutool_exists?`, and
`VideoPreviewer.accept?` calls `ffmpeg_exists?`. A package removed too early turns that processing off,
with no error and nothing in a log. The Hot Cell previewers' `accept?` doesn't look for a binary.

## Failures

The client raises the cell's `permanent:` or `transient:` class. See [Response codes](codes.md).

- **Analyzers** rescue the permanent class and return no metadata, so Rails marks the blob analyzed. They
  don't rescue the transient class. See [What Active Storage records](codes.md#what-active-storage-records).
- **Jobs** retry the transient class. At boot and on every code reload, the gem adds
  `retry_on <transient class>, wait: :polynomially_longer, attempts: 10` to `ActiveStorage::AnalyzeJob`,
  `ActiveStorage::CreateVariantsJob`, `ActiveStorage::PreviewImageJob`, and `ActiveStorage::TransformJob`,
  for each one that this Rails version has. Each registered cell that a shipped client names contributes
  its transient class. A cell that isn't registered yet contributes nothing.
- **`Previewers::Pdf::Mutool`** and **`Previewers::Pdf::Poppler`** answer `unreadable` with cause `protected`
  for a password-protected PDF. See [Causes of `unreadable`](codes.md#causes-of-unreadable).

## Limits

The shipped operations declare these limits. A cell clamps each one to its own limits. To change one, see
[Change a shipped operation's limits](operation-api.md#change-a-shipped-operations-limits).

| Routing name | `deadline` | `memory` | `file_size` | `open_files` |
| --- | --- | --- | --- | --- |
| `active_storage.transformers.image.vips` | 30 | 1280MB | 48MB | 256 |
| `active_storage.transformers.image.magick` | 30 | 1280MB | 48MB | 256 |
| `active_storage.analyzers.image.vips` | 10 | 1024MB | 48MB | 64 |
| `active_storage.analyzers.image.magick` | 10 | 1024MB | 48MB | 64 |
| `active_storage.analyzers.media.ffprobe` | 30 | 1024MB | 48MB | 128 |
| `active_storage.previewers.pdf.mutool` | 30 | 1024MB | 48MB | 128 |
| `active_storage.previewers.pdf.poppler` | 30 | 1024MB | 48MB | 128 |
| `active_storage.previewers.video.ffmpeg` | 120 | 1536MB | 128MB | 128 |

`MB` means 1024² bytes.

The 48MB is arithmetic from the README's accessory (four workers, two staged files each, on a 512MB
tmpfs), not a property of any operation. An operation that reads its input through the descriptor stages
only its output, so it needs half of what that arithmetic assumed. The shipped operations all read their
input through the descriptor.

A cell must allow the highest of these limits for every operation that it carries. See
[Tuning](tuning.md#size-against-the-container).
