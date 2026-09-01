# frozen_string_literal: true

module HotCell
  # A class and not a module: this file loads before hot_cell/client.rb opens the same name.
  class Client
    VERSION = "0.4.0.dev"
  end
end
