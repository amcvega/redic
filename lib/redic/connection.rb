require "redic/command_helper"
require "redic/errors"
require "socket"

class Redic
  module Connection
    TIMEOUT = 10.0

    module SocketMixin

      CRLF = "\r\n".freeze

      def initialize(*args)
        super(*args)

        @timeout = nil
        @buffer = ""
      end

      def timeout=(timeout)
        if timeout && timeout > 0
          @timeout = timeout
        else
          @timeout = nil
        end
      end

      def read(nbytes)
        result = @buffer.slice!(0, nbytes)

        while result.bytesize < nbytes
          result << _read_from_socket(nbytes - result.bytesize)
        end

        result
      end

      def gets
        crlf = nil

        while (crlf = @buffer.index(CRLF)) == nil
          @buffer << _read_from_socket(1024)
        end

        @buffer.slice!(0, crlf + CRLF.bytesize)
      end

      def _read_from_socket(nbytes)
        begin
          read_nonblock(nbytes)

        rescue Errno::EWOULDBLOCK, Errno::EAGAIN
          if IO.select([self], nil, nil, @timeout)
            retry
          else
            raise Redic::TimeoutError
          end
        end

      rescue EOFError
        raise Errno::ECONNRESET
      end
    end

    class TCPSocket < ::Socket

      include SocketMixin

      def self.connect(host, port)
        # Limit lookup to IPv4, as Redis doesn't yet do IPv6...
        addr = ::Socket.getaddrinfo(host, nil, Socket::AF_INET)
        sock = new(::Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)
        sockaddr = ::Socket.pack_sockaddr_in(port, addr[0][3])

        begin
          sock.connect_nonblock(sockaddr)
        rescue Errno::EINPROGRESS
          if IO.select(nil, [sock], nil, Connection::TIMEOUT) == nil
            raise TimeoutError
          end

          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
          end
        end

        sock
      end
    end

    class UNIXSocket < ::Socket

      include SocketMixin

      def self.connect(path)
        sock = new(::Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
        sockaddr = ::Socket.pack_sockaddr_un(path)

        begin
          sock.connect_nonblock(sockaddr)
        rescue Errno::EINPROGRESS
          if IO.select(nil, [sock], nil, Connection::TIMEOUT) == nil
            raise TimeoutError
          end

          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
          end
        end

        sock
      end
    end

    class Ruby
      include Redic::Connection::CommandHelper

      MINUS    = "-".freeze
      PLUS     = "+".freeze
      COLON    = ":".freeze
      DOLLAR   = "$".freeze
      ASTERISK = "*".freeze

      def self.connect(uri)
        if uri.scheme == "unix"
          sock = UNIXSocket.connect(uri.path)
        else
          sock = TCPSocket.connect(uri.host, uri.port)
        end

        instance = new(sock)
        instance
      end

      if [:SOL_SOCKET, :SO_KEEPALIVE, :SOL_TCP, :TCP_KEEPIDLE, :TCP_KEEPINTVL, :TCP_KEEPCNT].all?{|c| Socket.const_defined? c}
        def set_tcp_keepalive(keepalive)
          return unless keepalive.is_a?(Hash)

          @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE,  true)
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPIDLE,  keepalive[:time])
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPINTVL, keepalive[:intvl])
          @sock.setsockopt(Socket::SOL_TCP,    Socket::TCP_KEEPCNT,   keepalive[:probes])
        end

        def get_tcp_keepalive
          {
            :time   => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPIDLE).int,
            :intvl  => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPINTVL).int,
            :probes => @sock.getsockopt(Socket::SOL_TCP, Socket::TCP_KEEPCNT).int,
          }
        end
      else
        def set_tcp_keepalive(keepalive)
        end

        def get_tcp_keepalive
          {
          }
        end
      end

      def initialize(sock)
        @sock = sock
      end

      def connected?
        !! @sock
      end

      def disconnect
        @sock.close
      rescue
      ensure
        @sock = nil
      end

      def timeout=(timeout)
        if @sock.respond_to?(:timeout=)
          @sock.timeout = timeout
        end
      end

      def write(command)
        @sock.write(build_command(command))
      end

      def read
        line = @sock.gets
        reply_type = line.slice!(0, 1)
        format_reply(reply_type, line)

      rescue Errno::EAGAIN
        raise TimeoutError
      end

      def format_reply(reply_type, line)
        case reply_type
        when MINUS    then format_error_reply(line)
        when PLUS     then format_status_reply(line)
        when COLON    then format_integer_reply(line)
        when DOLLAR   then format_bulk_reply(line)
        when ASTERISK then format_multi_bulk_reply(line)
        else raise ProtocolError.new(reply_type)
        end
      end

      def format_error_reply(line)
        CommandError.new(line.strip)
      end

      def format_status_reply(line)
        line.strip
      end

      def format_integer_reply(line)
        line.to_i
      end

      def format_bulk_reply(line)
        bulklen = line.to_i
        return if bulklen == -1
        reply = encode(@sock.read(bulklen))
        @sock.read(2) # Discard CRLF.
        reply
      end

      def format_multi_bulk_reply(line)
        n = line.to_i
        return if n == -1

        Array.new(n) { read }
      end
    end
  end
end