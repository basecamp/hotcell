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
      # `timeout` covers the answer and not the connection. On Linux a blocking `connect` to a Unix socket waits
      # in the kernel while the listener's backlog is full, which is where a supervisor that stops calling
      # `accept` leaves it. `UNIXSocket.new` does not wait: Ruby opens every socket non-blocking and takes the
      # kernel's EAGAIN for a connection in progress, so it returns a socket that never connected. The send
      # fails with ENOTCONN, which `deliver` ignores, then the read fails with EINVAL, and the caller gets
      # `unavailable` at once. That is Ruby's behavior rather than this gem's, so ControlTimeoutTest holds it.
      #
      # If Ruby ever starts waiting, `connect_nonblock` plus `wait_writable` against a deadline would bound the
      # call only by spinning: on Linux an unconnected Unix socket is always writable, so it retries EAGAIN until
      # the deadline.
      def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
        connection = Connection.new(UNIXSocket.new(socket))
        deliver connection, line, descriptors
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
        # A full cell writes its answer and closes the connection without reading the request. The send can
        # then fail while the answer is already waiting on the socket. So this ignores the failed send, and
        # `receive` reads the answer. If the peer closed without an answer, `receive` reports that the
        # supervisor is gone.
        #
        # Linux fails that send with EPIPE or ECONNRESET. macOS usually does too, but answers ENOTCONN when the
        # close lands while its kernel is copying the request in, between checking the socket and queueing.
        def deliver(connection, line, descriptors)
          connection.send_message line, descriptors: descriptors
        rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ENOTCONN
          nil
        end

        # One absolute deadline across the whole response, not a wait for the first byte. Waiting for
        # readability and then calling a blocking read bounded nothing: a peer that sent one byte inside the
        # timeout and then stopped held this caller until the cell's own deadline, and a peer that never
        # closed held it forever — on a path an application may well be calling from a web request.
        def receive(connection, timeout)
          line = connection.read_line(deadline: timeout && Clock.now + timeout)
          return supervisor_gone if line.nil?

          Response.parse line
        rescue ReadTimeout
          failed "timeout", "the cell did not answer within #{timeout}s"
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
