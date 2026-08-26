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

require "hot_cell/railtie" if defined?(::Rails::Railtie)

module HotCell
  # The application side. A client class names the cell that serves it, and the call carries the same
  # three things an operation receives on the other side — with the payload Hash arriving there as
  # keyword arguments.
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
    # What a shared group is narrowed to on the way out, and the reason the group is safe to give away. A
    # cell may read an input and never write one; it may write an output and never read one. The kernel
    # applies these on every re-open by name, and the cell cannot widen either — changing a mode needs
    # ownership, the caller owns these files, and `cap-drop ALL` leaves no capability that overrides it.
    INPUT_MODE = 0o640
    OUTPUT_MODE = 0o620

    class << self
      include Declarations

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

      # Whether this client's named cell is registered, for a boot-time hook that must not raise on an
      # application that has bundled the gem and not yet written the initializer.
      def registered?
        !hotcell.nil? && HotCell.cell?(hotcell)
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
      # Explicit wrapping rather than Array(): an IO is Enumerable, so Array(io) reads the stream line by
      # line instead of wrapping it.
      inputs = [ inputs ] unless inputs.is_a?(Array)
      outputs = [ outputs ] unless outputs.is_a?(Array)

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
        inputs.map { |io| Input.new(shared(io, INPUT_MODE)) } +
          outputs.map { |io| Output.new(shared(io, OUTPUT_MODE)) }
      end

      # Through the descriptor rather than the path, so this names no file: fchown and fchmod take the open
      # file the caller already gave us. Both need ownership, which the caller has and the cell does not.
      #
      # **Accepted risk.** These are set and not put back, so the caller's file keeps this group and this
      # mode after the request — a `0600` file of the caller's own returns readable by the cell's group. The
      # premise is that restoring is worse than carrying it: the cell may still hold the descriptor, undoing
      # it mid-request adds a failure path to the answer, and a caller that could not share the file could
      # not use this at all. Active Storage hands over tempfiles it then unlinks, so nothing survives there.
      # docs/DEPLOYMENT.md tells anyone writing their own client to pass files they are willing to share.
      def shared(io, mode)
        return io if HotCell.group.nil?

        io.chown nil, HotCell.group
        io.chmod mode
        io
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
      # Only a measured zero, never a stat that failed. `byte_count` used to answer 0 for both, which turned
      # a descriptor this process could no longer stat into "the cell wrote nothing" — a transient failure
      # manufactured on a request that had succeeded, and a variant thrown away for it.
      def verify_output(response, outputs)
        return response if !response.ok? || outputs.empty?
        return response unless byte_count(outputs)&.zero?

        Response.failed Failure.new(code: "unavailable",
                                    message: "the cell reported success and wrote no bytes"),
                        timing: response.timing
      end

      # `code` belongs on the event rather than only on an exception. A caller configured to treat
      # `unreadable` as data would otherwise make those requests invisible, and unreadable rates are exactly
      # what you want to watch after a library upgrade. `capacity` matters for the same reason: without its
      # rate you cannot size a worker pool.
      #
      # The cause, signal and verdict go with it, because the code alone cannot classify a kill: `killed`
      # is permanent for fsize and memory and transient for deadline and crashed. A subscriber with only
      # the code filed every fsize kill as transient. `permanent` is the Failure's own answer, so no
      # subscriber re-derives it.
      #
      # A subscriber's own duration minus perform_ms is transport plus queueing, and those want separate
      # metrics: a rising perform_ms means the work got more expensive, and a rising difference means the
      # cell is saturated.
      def publish(event, cell, response, inputs, outputs)
        failure = response.failure

        event[:operation] = self.class.operation
        event[:cell] = cell.name
        event[:code] = failure&.code
        event[:cause] = failure&.cause
        event[:signal] = failure&.signal
        event[:permanent] = failure&.permanent?
        event[:bytes_in] = byte_count(inputs)
        event[:bytes_out] = byte_count(outputs)
        event[:perform_ms] = response.timing[:perform_ms]
        event[:timing] = response.timing
      end

      # nil means "could not measure", which is not the same fact as zero and must not be confused with it.
      def byte_count(ios)
        ios.sum { |io| io.stat.size }
      rescue SystemCallError, IOError
        nil
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
