# frozen_string_literal: true

require "socket"

module HotCell
  # The transport is a seam, and the socket one is the only implementation used outside tests.
  #
  # It never reconnects and never retries. One request per connection invites exactly that on
  # ECONNREFUSED, and a silent retry doubles a cell's load at the moment it is least able to take it.
  # Retry belongs in the job layer, which is the whole reason the transient class exists.
  module Transport
    class Socket
      def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
        connection = Connection.new(UNIXSocket.new(socket))
        connection.send_message line, descriptors: descriptors
        receive connection, timeout
      rescue SystemCallError, IOError => error
        # A socket that does not exist, a cell that is restarting, an accessory not yet booted. These are
        # the most likely failures in production and they produce no wire response at all, so they belong
        # in the taxonomy rather than outside it — otherwise the code on the instrumentation event is blank
        # for exactly the outage you most want to see.
        unavailable error
      ensure
        connection&.close
      end

      private
        def receive(connection, timeout)
          unless timeout.nil? || connection.socket.wait_readable(timeout)
            return failed("timeout", "the cell did not answer within #{timeout}s")
          end

          line = connection.read_line
          return supervisor_gone if line.nil?

          Response.parse line
        rescue MessageError => error
          unavailable "the cell's answer could not be read: #{error.message}"
        end

        # A live supervisor answers `killed` for a worker that died, which is the whole reason it holds a
        # copy of the connection. So a connection that closes with no response at all means the supervisor
        # itself is gone.
        def supervisor_gone
          unavailable "the connection closed with no response, so the cell's supervisor is gone"
        end

        # Takes a String or an Exception; Failure.for splits an Exception into its two wire fields.
        def unavailable(detail)
          failed "unavailable", detail
        end

        def failed(code, detail)
          Response.failed Failure.for(code, detail)
        end
    end
  end
end
