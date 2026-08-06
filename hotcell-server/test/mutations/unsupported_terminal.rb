# An operation a cell does not carry yet, recorded as a permanent verdict on the blob.
require "hot_cell/server"
HotCell::Codes::TERMINAL.dup.tap do |table|
  table["unsupported"] = true
  HotCell::Codes.send :remove_const, :TERMINAL
  HotCell::Codes.const_set :TERMINAL, table.freeze
end
