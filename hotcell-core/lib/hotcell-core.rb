# frozen_string_literal: true

# Bundler auto-requires a gem named "hotcell-core" as "hotcell-core", then as "hotcell/core". This gem
# uses neither path, because hot_cell/ is what yields the HotCell constant under the default inflection.
# Without this file, `gem "hotcell-core"` in a Gemfile silently loads nothing at all.
require "hot_cell/core"
