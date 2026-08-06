# frozen_string_literal: true

# Bundler auto-requires a gem named "hotcell-client" as "hotcell-client", then as "hotcell/client". This
# gem uses neither path, because hot_cell/ is what yields the HotCell constant under the default inflection.
# Without this file, `gem "hotcell-client"` in a Gemfile silently loads nothing at all.
require "hot_cell/client"
