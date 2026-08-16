# frozen_string_literal: true

require "active_storage/hot_cell/client/tool_arguments"

module ActiveStorage
  module HotCell
    module Client
      module Analyzers
        # What the two ffprobe analyzers add to the shared round trip: `config.active_storage.ffprobe_arguments`,
        # which Rails' own video and audio analyzers splice before the input path, carried to the cell so it
        # can do the same. Split here, the way Rails splits it, and omitted entirely when it is empty.
        module Probing
          private
            def payload
              ToolArguments.payload(:probe_arguments, ActiveStorage.ffprobe_arguments)
            end
        end
      end
    end
  end
end
