# frozen_string_literal: true

# Bundler auto-requires a gem named "yabeda-hotcell" as "yabeda-hotcell", then as "yabeda/hotcell". This gem
# uses neither path, because hot_cell/ is what yields the HotCell constant under the default inflection.
require "yabeda/hot_cell"
