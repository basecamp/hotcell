# frozen_string_literal: true

# Bundler auto-requires a gem named "hotcell-server" as "hotcell-server", then as "hotcell/server". This
# gem uses neither path, because hot_cell/ is what yields the HotCell constant under the default
# inflection. Without this file, `gem "hotcell-server"` in a Gemfile silently loads nothing at all.
require "hot_cell/server"
