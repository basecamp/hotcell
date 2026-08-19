# frozen_string_literal: true

module HotCell
  # A class and not a module: this file loads before hot_cell/client.rb opens the same name.
  class Client
    VERSION = "0.1.0"
  end
end
