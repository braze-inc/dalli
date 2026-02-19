# frozen_string_literal: true

module Dalli
  module Socket
    module InstanceMethods
      def readfull(count)
        value = String.new(capacity: count + 1)
        loop do
          result = read_nonblock(count - value.bytesize, exception: false)
          if result == :wait_readable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select([self], nil, nil, options[:socket_timeout])
          elsif result == :wait_writable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select(nil, [self], nil, options[:socket_timeout])
          elsif result
            value << result
          else
            raise Errno::ECONNRESET, "Connection reset: #{safe_options.inspect}"
          end
          break if value.bytesize == count
        end
        value
      end

      def writefull(bytes)
        offset = 0
        while offset < bytes.bytesize
          chunk = offset == 0 ? bytes : bytes.byteslice(offset..-1)
          result = write_nonblock(chunk, exception: false)
          if result == :wait_writable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select(nil, [self], nil, options[:socket_timeout])
          elsif result == :wait_readable
            raise Timeout::Error, "IO timeout: #{safe_options.inspect}" unless IO.select([self], nil, nil, options[:socket_timeout])
          else
            offset += result
          end
        end
        offset
      end

      def read_available
        value = +""
        loop do
          result = read_nonblock(8196, exception: false)
          if result == :wait_readable
            break
          elsif result == :wait_writable
            break
          elsif result
            value << result
          else
            raise Errno::ECONNRESET, "Connection reset: #{safe_options.inspect}"
          end
        end
        value
      end

      def safe_options
        options.reject { |k, v| [:username, :password].include? k }
      end
    end

    class TCP < ::Socket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(host, port, server, options = {})
        addr_info = ::Socket.getaddrinfo(host, nil, ::Socket::AF_UNSPEC, ::Socket::SOCK_STREAM)
        ai = addr_info.first
        sock = new(ai[4], ::Socket::SOCK_STREAM, 0)

        sock.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, true)
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true) if options[:keepalive]
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVBUF, options[:rcvbuf]) if options[:rcvbuf]
        sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF, options[:sndbuf]) if options[:sndbuf]

        sockaddr = ::Socket.pack_sockaddr_in(port, ai[3])
        result = sock.connect_nonblock(sockaddr, exception: false)
        if result == :wait_writable
          unless IO.select(nil, [sock], nil, options[:socket_timeout])
            raise Timeout::Error, "Connection timeout: #{host}:#{port}"
          end
          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
            # already connected
          end
        end

        sock.options = { host: host, port: port }.merge(options)
        sock.server = server
        sock
      rescue
        sock&.close rescue nil
        raise
      end
    end

    class UNIX < ::Socket
      include Dalli::Socket::InstanceMethods
      attr_accessor :options, :server

      def self.open(path, server, options = {})
        sock = new(::Socket::AF_UNIX, ::Socket::SOCK_STREAM, 0)
        sockaddr = ::Socket.pack_sockaddr_un(path)

        result = sock.connect_nonblock(sockaddr, exception: false)
        if result == :wait_writable
          unless IO.select(nil, [sock], nil, options[:socket_timeout])
            raise Timeout::Error, "Connection timeout: #{path}"
          end
          begin
            sock.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
            # already connected
          end
        end

        sock.options = { path: path }.merge(options)
        sock.server = server
        sock
      rescue
        sock&.close rescue nil
        raise
      end
    end
  end
end
