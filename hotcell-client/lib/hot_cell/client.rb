# frozen_string_literal: true

require "hot_cell/core"

# Notifications reaches for IsolatedExecutionState the moment something is actually subscribed, and not
# before — so requiring only notifications works until the first subscriber appears and then raises
# NameError in production.
require "active_support/isolated_execution_state"
require "active_support/notifications"

require "hot_cell/client/version"
require "hot_cell/failures"
require "hot_cell/transport"
require "hot_cell/cell"
require "hot_cell/cells"

module HotCell
  # The application side. A client class names the cell that serves it, and the call signature is the same
  # three arguments an operation receives on the other side.
  #
  #   class ArchiveFolder < HotCell::Client
  #     hotcell "archiver"
  #   end
  #
  #   ArchiveFolder.perform_in_hotcell(inputs, outputs, payload)
  #
  # Routing is a class-level declaration rather than a call-site argument, so call sites carry no deployment
  # detail and several clients may name the same cell.
  class Client
    class << self
      include Declarations

      def inherited(subclass)
        super
        HotCell.clients << subclass
      end

      def hotcell(name = nil)
        return inherited_value(:@cell_name) if name.nil?

        @cell_name = name.to_s
      end

      def operation(name = nil)
        return @operation_name || Naming.default_operation_name(self) if name.nil?

        @operation_name = name.to_s
      end

      def cell
        name = hotcell
        raise ConfigurationError, "#{self} must name its cell with `hotcell \"a_name\"`" if name.nil?

        HotCell.cell name
      end

      # Whether this path is turned on. A caller that finds it off runs in process exactly as it did before,
      # which is the whole rollout mechanism.
      def enabled?
        cell.enabled?
      end

      def perform_in_hotcell(inputs, outputs, payload = {})
        new.perform_in_hotcell inputs, outputs, payload
      end
    end

    def perform_in_hotcell(inputs, outputs, payload = {})
      cell = self.class.cell

      unless cell.enabled?
        raise CellNotConfigured, "cell #{cell.name.inspect} has no socket directory, so this path is off"
      end

      # Everything up to here raises for itself, above the transport's rescue and on purpose. A payload
      # value JSON cannot carry, a descriptor with the wrong access mode, or a request over the byte limit
      # are this caller's bugs. An application whose transient class descends from IOError would otherwise
      # have its own bad call reclassified as a socket failure and retried forever.
      descriptors = wrap(inputs, outputs)
      line = request_line(inputs, outputs, payload)

      response = nil
      ActiveSupport::Notifications.instrument "perform.hot_cell" do |event|
        response = verify_output(cell.transport.call(cell, line, descriptors), outputs)
        publish event, cell, response, inputs, outputs
      end

      raise_for response, cell
      response.result
    end

    private
      def wrap(inputs, outputs)
        inputs.map { |io| Input.new(io) } + outputs.map { |io| Output.new(io) }
      end

      def request_line(inputs, outputs, payload)
        Request.new(op: self.class.operation, inputs: inputs.size, outputs: outputs.size,
                    payload: payload).to_line
      end

      # `ok` with zero bytes written is a failure, and the client is where it has to be caught. The worker
      # flushes before reporting success, so this should not happen — which is precisely why it must be
      # handled rather than assumed away. A full tmpfs on the cell arrives this way, as ENOSPC from the copy
      # rather than from the socket, and a full filesystem must never be recorded as "this document is
      # unprocessable". So it is transient, not a valid empty image.
      def verify_output(response, outputs)
        return response if !response.ok? || outputs.empty?
        return response unless byte_count(outputs).zero?

        Response.failed Failure.new(code: "unavailable",
                                    message: "the cell reported success and wrote no bytes"),
                        timing: response.timing
      end

      # `code` belongs on the event rather than only on an exception. A caller configured to treat
      # `unreadable` as data would otherwise make those requests invisible, and unreadable rates are exactly
      # what you want to watch after a library upgrade. `capacity` matters for the same reason: without its
      # rate you cannot size a worker pool.
      #
      # A subscriber's own duration minus perform_ms is transport plus queueing, and those want separate
      # metrics: a rising perform_ms means the work got more expensive, and a rising difference means the
      # cell is saturated.
      def publish(event, cell, response, inputs, outputs)
        event[:operation] = self.class.operation
        event[:cell] = cell.name
        event[:code] = response.failure&.code
        event[:bytes_in] = byte_count(inputs)
        event[:bytes_out] = byte_count(outputs)
        event[:perform_ms] = response.timing[:perform_ms]
        event[:timing] = response.timing
      end

      def byte_count(ios)
        ios.sum { |io| io.stat.size }
      rescue SystemCallError, IOError
        0
      end

      def raise_for(response, cell)
        return if response.ok?

        failure = response.failure
        error = cell.exception_for(failure).new(failure.to_s)
        cell.report_contract_skew error if failure.code == "protocol"

        raise error
      end
  end
end
