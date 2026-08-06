# Trusting `ok` without looking at the output, which is how a full tmpfs on the cell gets recorded as an
# unprocessable document.
require "hot_cell/client"
module HotCell; class Client; private def verify_output(response, _outputs) = response; end; end
