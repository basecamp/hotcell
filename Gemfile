# frozen_string_literal: true

source "https://rubygems.org"

gemspec path: "hotcell-core",   name: "hotcell-core"
gemspec path: "hotcell-client", name: "hotcell-client"
gemspec path: "hotcell-server", name: "hotcell-server"

gemspec path: "activestorage-hotcell-client", name: "activestorage-hotcell-client"
gemspec path: "activestorage-hotcell-server", name: "activestorage-hotcell-server"

# activestorage-hotcell-client needs config.active_storage.variant_processor to accept a class, which is
# rails/rails#58384. Merged, unreleased — so this tracks main until 8.2 ships and the gemspec floor can name
# a version instead.
gem "activestorage", github: "rails/rails", branch: "main"
gem "activesupport", github: "rails/rails", branch: "main"

gem "minitest"
gem "rake"

group :development do
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-packaging", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rake", require: false
end
