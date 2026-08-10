# frozen_string_literal: true

require "socket"

module HotCell
  # One request per connection: the cold side connects, sends one request with its descriptors, reads
  # one response line, and closes. The hot side never initiates.
  #
  # SOCK_STREAM rather than SOCK_SEQPACKET, and the receiver pays for it. Real message boundaries would
  # remove the framing problem outright, and Darwin has no AF_UNIX SOCK_SEQPACKET, so a stream socket is
  # what there is. A stream socket does not promise that one sendmsg arrives as one recvmsg, and the
  # ancillary data rides on whichever bytes land first. So read to the newline in a loop, and take the
  # descriptors from whichever recvmsg carried them rather than from the one that completes the line.
  #
  # An implementation that assumes one sendmsg is one recvmsg passes every test small enough not to
  # fragment, which is why this is written down here rather than left to be rediscovered.
  class Connection
    CHUNK_BYTES = 4096

    attr_reader :socket

    def initialize(socket)
      @socket = socket
    end

    # So that a connection can itself be passed over SCM_RIGHTS. That is how the supervisor hands an
    # accepted connection to a worker without reading it: the caller's descriptors stay queued on the
    # connection until somebody calls recvmsg, and the worker is the one who does.
    def to_io
      socket
    end

    # The descriptors ride the first sendmsg and the rest of the line follows as ordinary writes, because a
    # stream socket does not promise that one sendmsg sends all of it. The return value used to be ignored:
    # a short send that carried the ancillary data left the receiver holding the descriptors and waiting for
    # a newline that never came, while this side moved on to waiting for a response. Both ends then sat
    # until something else timed them out — and the caller's descriptors were installed in the cell either
    # way, so it is not a case that fails safe.
    #
    # Ancillary data goes exactly once. Sending it again with a later chunk would install a second copy of
    # every descriptor in the receiver.
    def send_message(line, descriptors: [])
      sent = if descriptors.empty?
        socket.sendmsg line
      else
        socket.sendmsg line, 0, nil, Socket::AncillaryData.unix_rights(*descriptors.map(&:to_io))
      end

      write_all line.byteslice(sent..) if sent < line.bytesize
    end

    # Returns [line, descriptors]. The line is nil when the peer closed without sending anything.
    #
    # The caller owns the descriptors and must close every one of them, including any it will not use.
    # A request that is refused still arrives with its descriptors installed in this process.
    def receive_message(limit: MAX_REQUEST_BYTES)
      buffer = "".b
      descriptors = []

      loop do
        chunk, _, _, *controls = socket.recvmsg(CHUNK_BYTES, 0, nil, scm_rights: true)
        descriptors.concat controls.flat_map(&:unix_rights)

        break if chunk.nil? || chunk.empty?
        buffer << chunk
        break if buffer.include?("\n")

        raise MessageError, "message passed #{limit} bytes with no newline" if buffer.bytesize > limit
      end

      [ line_from(buffer, limit), descriptors ]
    rescue StandardError
      descriptors.each { |descriptor| descriptor.close unless descriptor.closed? }
      raise
    end

    # IO#write already loops until everything is written or it raises, which sendmsg does not.
    def write_line(line)
      write_all line
    end

    # UTF-8 for the same reason receive_message forces it: a socket read comes back ASCII-8BIT, where every
    # byte is "valid" and nothing downstream can tell a mis-encoded message from a good one. Both directions
    # should behave the same way, and the one that scrubs is Failure.
    #
    # `deadline` is an absolute instant covering the whole line rather than a per-read timeout, because a
    # per-read one bounds nothing. Waiting for the socket to be readable and then calling a blocking `gets`
    # meant a peer that sent a single byte inside the timeout and then stopped held the caller until the
    # cell's own deadline, or forever against a peer that never closed. Returns nil at end of stream, and
    # raises Timeout when the deadline passes with the line incomplete.
    def read_line(limit: MAX_RESPONSE_BYTES, deadline: nil)
      buffer = "".b

      until buffer.end_with?("\n")
        chunk = read_chunk(deadline)

        if chunk.nil?
          return nil if buffer.empty?

          raise MessageError, "message ended after #{buffer.bytesize} bytes with no newline"
        end

        buffer << chunk
        raise MessageError, "message passed #{limit} bytes with no newline" if buffer.bytesize > limit
      end

      buffer.force_encoding Encoding::UTF_8
    end

    def close
      socket.close unless socket.closed?
    end

    private
      def write_all(bytes)
        socket.write bytes
      end

      # Returns nil at end of stream. With no deadline this blocks, which is what the cell's own side wants —
      # it is bounded by the supervisor rather than by a clock here.
      def read_chunk(deadline)
        if deadline
          remaining = deadline - Clock.now

          unless remaining.positive? && socket.wait_readable(remaining)
            raise ReadTimeout, "the peer stopped mid-message and the deadline passed"
          end
        end

        socket.readpartial CHUNK_BYTES
      rescue EOFError
        nil
      end

      def line_from(buffer, limit)
        return nil if buffer.empty?

        newline = buffer.index("\n")
        raise MessageError, "message ended after #{buffer.bytesize} bytes with no newline" if newline.nil?

        if newline < buffer.bytesize - 1
          raise MessageError, "#{buffer.bytesize - newline - 1} bytes follow the message line, and one " \
                              "connection carries one message"
        end
        raise MessageError, "message is #{buffer.bytesize} bytes, over the #{limit} byte limit" if buffer.bytesize > limit

        buffer.force_encoding Encoding::UTF_8
      end
  end
end
