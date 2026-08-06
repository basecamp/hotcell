# frozen_string_literal: true

source "https://rubygems.org"

gemspec path: "hotcell-core",   name: "hotcell-core"
gemspec path: "hotcell-client", name: "hotcell-client"
gemspec path: "hotcell-server", name: "hotcell-server"

gemspec path: "activestorage-hotcell-client", name: "activestorage-hotcell-client"
gemspec path: "activestorage-hotcell-server", name: "activestorage-hotcell-server"

# activestorage-hotcell-client needs config.active_storage.variant_processor to accept a class, which is
# rails/rails#58384 and unmerged. Without it, engine.rb's `case` has no `else`, so a class value leaves
# ActiveStorage.variant_transformer at nil and the first variant dies with NoMethodError — not a boot error.
gem "activestorage", github: "flavorjones/rails", branch: "variant-transformer-seam"
gem "activesupport", github: "flavorjones/rails", branch: "variant-transformer-seam"

gem "minitest"
gem "rake"
