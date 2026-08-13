# HotCell and Active Storage

The two `activestorage-hotcell-*` gems are the shipped, worked example of building on HotCell: operations
covering transforms, analysis and previews, and the client-side transformers, analyzers and previewers
Rails is configured with:

```ruby
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Image::Vips
config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Image::Vips,
                                    ActiveStorage::HotCell::Client::Analyzers::Video::FFprobe,
                                    ActiveStorage::HotCell::Client::Analyzers::Audio::FFprobe ]
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::HotCell::Client::Previewers::Video::FFmpeg ]
```

That is one configuration of several. Images can go through ImageMagick instead of libvips
(`Transformers::Image::Magick`, `Analyzers::Image::Magick`), and PDFs through Poppler instead of mutool
(`Previewers::Pdf::Poppler`). Pick the pair your cell's image installs the tools for.

Classes are named role, then subject, then tool — `Analyzers::Image::Vips` — so lexical order groups
siblings, and an operation's wire name is the snake-cased class path: `active_storage.analyzers.image.vips`.
The tool leaf is spelled `Ffprobe`/`Ffmpeg`/`Pdf` so that rule holds mechanically; `FFprobe`, `FFmpeg` and
`PDF` are aliases.

Those declarations are the only thing an application writes; a railtie does the rest, including adding the
transient class to Active Storage's jobs' retry policies. The client gem exists because the built-in
classes break the moment their tools leave the image: the image analyzers decline once `variant_processor`
is a class and blobs are marked analyzed with no dimensions; the video and audio analyzers answer `accept?`
by shelling out to ffprobe and go silent when it is gone; the previewers do the same with mutool and ffmpeg;
and the jobs retry nothing useful. Each is closed in the gem, where the breakage is documented. The video
and audio analyzers present exactly Rails' metadata, with one deliberate exception — Rails writes a media
file's raw container `tags` into the database, and the cell refuses them, because those bytes are
attacker-controlled.

## What inherits from Rails, and what does not

The client classes subclass Rails' own. The previewers subclass
`ActiveStorage::Previewer::MuPDFPreviewer`, `PopplerPDFPreviewer` and `VideoPreviewer`.
`Transformers::Image::Magick` subclasses `ActiveStorage::Transformers::ImageMagick`. The analyzers
subclass `ActiveStorage::Analyzer`. They inherit `accept?`, the transformation allowlist, and the metadata
shape. One step changes. The work crosses to a cell instead of running in the application.

The cell's operations inherit nothing from Rails. They subclass `HotCell::Operation`. Each operation
reimplements what a Rails class does, with the same library and the same pipeline.
`Transformers::Image::Vips` runs `source(…).loader(page: 0).convert(format).apply(operations)` through
`ImageProcessing::Vips`, as `ActiveStorage::Transformers::ImageProcessingTransformer` does.

Nothing keeps the operations in step with Rails. When Rails changes a transformer or an analyzer, update
the operation by hand.

**`activestorage-hotcell-server` does not load Active Storage**, despite the name. The name says which
consumer it serves, not what it links against. Everything application-side lives under
`ActiveStorage::HotCell::Client` and everything cell-side under `ActiveStorage::HotCell::Server`, because a
cell is forked from a process that may have loaded the client, and a shared name would be a superclass
mismatch at boot.

## Status

`activestorage-hotcell-client` depends on
[rails/rails#58384](https://github.com/rails/rails/pull/58384), which is merged and unreleased — so the
Gemfile tracks `main` until 8.2 ships and the gemspec floor can name a version.

Not yet, in the order they matter:

**A transformation allowlist.** Today the cell matches Rails' vips path exactly, in
`Server::Transforming#operations_for`: it refuses `combine_options`, drops blank arguments, and passes
every other transformation, `loader`, and `saver` straight to ImageProcessing. So a caller can set `loader: { unlimited: true }` and remove libvips' own
denial-of-service limits — the capability Rails gives a caller today, tolerable here only because the cell's
limits are outside the library (`RLIMIT_DATA`, `RLIMIT_FSIZE` and the wall-clock deadline still apply, so the
caller buys a killed worker). A future deliverable narrows this to an explicit allowlist: which operations
are permitted, and which keys inside `loader`/`saver` (`page`, `n`, `quality`, `strip` yes; `unlimited`,
`access`, `fail-on`, `revalidate` no). It must be one visible list rather than a filter hidden in a
translation step, and it is deliberately not present yet.

**Cell-side allowlist enforcement.** Rails' ImageMagick transformer enforces
`supported_image_processing_methods` and an argument blocklist, and the client `Transformers::Image::Magick`
keeps that check where Rails runs it — in the application, before a request crosses to the cell. The vips
path has no such allowlist, in Rails or here. A future enhancement moves an explicit allowlist into the cell
itself, so the boundary rather than the caller's configuration is what bounds the operation set; until then
the cell applies what it is sent, bounded by its resource limits.
