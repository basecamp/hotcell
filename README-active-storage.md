# HotCell and Active Storage

The `activestorage-hotcell-*` gems run Active Storage's variants, analysis and previews in a cell instead
of in the application. Call sites do not change.

See [README.md](README.md) for what a cell is, and [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for how to
build and deploy one.

## Rails

You need Rails 8.2, which supports setting `config.active_storage.variant_processor` to a class
([rails/rails#58384](https://github.com/rails/rails/pull/58384)).

As of this writing, Rails 8.2 is not released, so we recommend you use the `main` branch.

## Install

### How to get started

Everything about a cell lives in a `hotcell/` directory in the application root, separate from the
client configuration and the application code. That directory holds:

- a `Gemfile` for what the operations need,
- a `Dockerfile` that builds the cell's image,
- a `config.rb` for the cell's own settings, and
- an `operations/` directory of Ruby files the cell loads at boot.

Running `bin/rails hotcell:install` creates all of them.

### Dependencies

```ruby
# Gemfile — the application
gem "activestorage-hotcell-client"
```

```ruby
# hotcell/Gemfile — the cell
gem "activestorage-hotcell-server"
```

### Application initialization and configuration

Register the cell. Give it an exception class for each side of the permanent split.

```ruby
# config/initializers/hotcell.rb
HotCell.root  = ENV["HOTCELL_ROOT"]           # without a value, every cell is off
HotCell.group = Integer(ENV["HOTCELL_GROUP"]) # the cell's gid; this application must be in that group

HotCell.register "active_storage",
  permanent: MyApp::UnprocessableUpload,
  transient: MyApp::ConversionTemporarilyUnavailable

# Warns at boot about a cell that is unreachable, missing an operation, or in the wrong group.
# It never raises.
Rails.application.config.after_initialize { HotCell.describe_cells }
```

Then tell Rails which classes to use.

```ruby
# config/application.rb
config.active_storage.variant_processor = ActiveStorage::HotCell::Client::Transformers::Image::Vips
config.active_storage.analyzers = [ ActiveStorage::HotCell::Client::Analyzers::Image::Vips,
                                    ActiveStorage::HotCell::Client::Analyzers::Video::FFprobe,
                                    ActiveStorage::HotCell::Client::Analyzers::Audio::FFprobe ]
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::HotCell::Client::Previewers::Video::FFmpeg ]
```

The classes in this example use libvips, mutool and ffmpeg. `Transformers::Image::Magick` and
`Analyzers::Image::Magick` use ImageMagick instead, and `Previewers::Pdf::Poppler` uses Poppler. For
every class you name, the cell must load the matching operation and install the tool. You need to
make sure the underlying container image also contains the necessary system packages for your
toolchain.

You can mix Rails' own classes with the `ActiveStorage::HotCell::Client` classes in the
`analyzers` and `previewers` configuration arrays if you wish:

```ruby
# PDF previews handled by HotCell, video previews still in the application
config.active_storage.previewers = [ ActiveStorage::HotCell::Client::Previewers::Pdf::Mutool,
                                     ActiveStorage::Previewer::VideoPreviewer ]
```

The application writes nothing else. A railtie makes Active Storage's jobs retry the transient class.

### Keep the attack surface small

Once media processing for a file type has been moved into HotCell, we recommend you remove the
underlying system package (e.g., `libvips`) from the application container. Rails' previewers and
analyzers look for their tool in `accept?`, so a package removed too early turns that processing off
without an error.
