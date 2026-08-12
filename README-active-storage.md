# HotCell and Active Storage

The two `activestorage-hotcell-*` gems are the shipped, worked example of building on HotCell: five
operations covering transforms, analysis and previews, and the client-side transformer, analyzer and
previewers Rails is configured with:

```ruby
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Vips
config.active_storage.analyzers.prepend ActiveStorage::HotCell::Client::Analyzers::ImageAnalyzer::Vips
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::PdfPreviewer,
                                     ActiveStorage::HotCell::Client::VideoPreviewer ]
```

Those declarations are the only thing an application writes; a railtie does the rest, including adding the
transient class to the four Active Storage jobs' retry policies. The client gem exists because three things
break the moment `variant_processor` is a class rather than a symbol: the built-in analyzers decline and
blobs are marked analyzed with no dimensions, the built-in previewers answer `accept?` by shelling out to
binaries that have left the image, and the jobs retry nothing useful. Each is closed in the gem, where the
breakage is documented.

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

**A transformation allowlist.** Today the transformer matches Rails' vips path exactly: it refuses
`combine_options`, drops blank arguments, and passes every other transformation, `loader`, and `saver`
straight to ImageProcessing. So a caller can set `loader: { unlimited: true }` and remove libvips' own
denial-of-service limits — the capability Rails gives a caller today, tolerable here only because the cell's
limits are outside the library (`RLIMIT_DATA`, `RLIMIT_FSIZE` and the wall-clock deadline still apply, so the
caller buys a killed worker). A future deliverable narrows this to an explicit allowlist: which operations
are permitted, and which keys inside `loader`/`saver` (`page`, `n`, `quality`, `strip` yes; `unlimited`,
`access`, `fail-on`, `revalidate` no). It must be one visible list rather than a filter hidden in a
translation step, and it is deliberately not present yet.

**An ImageMagick-compatible transformer and analyzer.** `Transformers::Vips` and
`Analyzers::ImageAnalyzer::Vips` are named for their toolchain so these can sit beside them. Until they exist,
URLs minted on `mini_magick` — carrying `coalesce`, or top-level `quality` and `strip` — are refused, exactly
as they raise under Rails on vips. An application moving between the two rewrites them at its own boundary in
the meantime, the way BC4 does.
