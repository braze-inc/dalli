# frozen_string_literal: true
require 'socket'
require 'timeout'

require 'dalli/pid_cache'

module Dalli
  module Protocol
    class Base
      attr_accessor :hostname
      attr_accessor :port
      attr_accessor :weight
      attr_accessor :options
      attr_reader :sock
      attr_reader :socket_type

      DEFAULT_PORT = 11211
      DEFAULT_WEIGHT = 1
      DEFAULTS = {
        :down_retry_delay => 60,
        :socket_timeout => 0.5,
        :socket_max_failures => 2,
        :socket_failure_delay => 0.01,
        :value_max_bytes => 1024 * 1024,
        :error_when_over_max_size => false,
        :compressor => Compressor,
        :compression_min_size => 1024,
        :compression_max_size => false,
        :serializer => Marshal,
        :username => nil,
        :password => nil,
        :keepalive => true,
        :sndbuf => nil,
        :rcvbuf => nil
      }

      ALLOWED_MULTI_OPS = %i[set setq delete deleteq add addq replace replaceq].freeze

      # http://www.hjp.at/zettel/m/memcached_flags.rxml
      FLAG_SERIALIZED = 0x1
      FLAG_COMPRESSED = 0x2

      MAX_ACCEPTABLE_EXPIRATION_INTERVAL = 30*24*60*60 # 30 days

      class NilObject; end
      NOT_FOUND = NilObject.new

      def initialize(attribs, options = {})
        @hostname, @port, @weight, @socket_type = parse_hostname(attribs)
        @fail_count = 0
        @down_at = nil
        @last_down_at = nil
        @options = DEFAULTS.merge(options)
        @sock = nil
        @msg = nil
        @error = nil
        @pid = nil
        @inprogress = nil
        @pending_multi_response = nil
      end

      def name
        if socket_type == :unix
          hostname
        else
          "#{hostname}:#{port}"
        end
      end

      # Chokepoint method for instrumentation
      def request(op, *args)
        verify_state
        raise Dalli::NetworkError, "#{name} is down: #{@error} #{@msg}. If you are sure it is running, ensure memcached version is > 1.4." unless alive?
        begin
          if @pending_multi_response && (!multi? || !ALLOWED_MULTI_OPS.include?(op))
            noop
            @pending_multi_response = false
          end
          send(op, *args)
        rescue Dalli::MarshalError => ex
          Dalli.logger.error "Marshalling error for key '#{args.first}': #{ex.message}"
          Dalli.logger.error "You are trying to cache a Ruby object which cannot be serialized to memcached."
          Dalli.logger.error ex.backtrace.join("\n\t")
          false
        rescue Timeout::Error
          close
          raise
        rescue Dalli::DalliError, Dalli::NetworkError, Dalli::ValueOverMaxSize
          raise
        rescue => ex
          Dalli.logger.error "Unexpected exception during Dalli request: #{ex.class.name}: #{ex.message}"
          Dalli.logger.error ex.backtrace.join("\n\t")
          down!
        end
      end

      def alive?
        return true if @sock

        if @last_down_at && @last_down_at + options[:down_retry_delay] >= Time.now
          time = @last_down_at + options[:down_retry_delay] - Time.now
          Dalli.logger.debug { "down_retry_delay not reached for #{name} (%.3f seconds left)" % time }
          return false
        end

        connect
        !!@sock
      rescue Dalli::NetworkError
        false
      end

      def close
        return unless @sock
        @sock.close rescue nil
        @sock = nil
        @pid = nil
        @inprogress = false
      end

      def lock!
      end

      def unlock!
      end

      def serializer
        @options[:serializer]
      end

      def compressor
        @options[:compressor]
      end

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      def verify_state
        failure!(RuntimeError.new('Already writing to socket')) if @inprogress
        if @pid && @pid != PIDCache.pid
          message = 'Fork detected, re-connecting child process...'
          Dalli.logger.info { message }
          reconnect! message
        end
      end

      def reconnect!(message)
        close
        sleep(options[:socket_failure_delay]) if options[:socket_failure_delay]
        raise Dalli::NetworkError, message
      end

      def failure!(exception)
        message = "#{name} failed (count: #{@fail_count}) #{exception.class}: #{exception.message}"
        Dalli.logger.warn { message }

        @fail_count += 1
        if @fail_count >= options[:socket_max_failures]
          down!
        else
          reconnect! 'Socket operation failed, retrying...'
        end
      end

      def down!
        close

        @last_down_at = Time.now

        if @down_at
          time = Time.now - @down_at
          Dalli.logger.debug { "#{name} is still down (for %.3f seconds now)" % time }
        else
          @down_at = @last_down_at
          Dalli.logger.warn { "#{name} is down" }
        end

        @error = $! && $!.class.name
        @msg = @msg || ($! && $!.message && !$!.message.empty? && $!.message)
        raise Dalli::NetworkError, "#{name} is down: #{@error} #{@msg}"
      end

      def up!
        if @down_at
          time = Time.now - @down_at
          Dalli.logger.warn { "#{name} is back (downtime was %.3f seconds)" % time }
        end

        @fail_count = 0
        @down_at = nil
        @last_down_at = nil
        @msg = nil
        @error = nil
      end

      def multi?
        Thread.current[:dalli_multi]
      end

      def write(bytes)
        begin
          @inprogress = true
          result = @sock.write(bytes)
          @inprogress = false
          result
        rescue SystemCallError, Timeout::Error => e
          failure!(e)
        end
      end

      def read(count)
        begin
          @inprogress = true
          data = @sock.readfull(count)
          @inprogress = false
          data
        rescue SystemCallError, Timeout::Error, EOFError => e
          failure!(e)
        end
      end

      def serialize(key, value, options=nil)
        marshalled = false
        value = unless options && options[:raw]
          marshalled = true
          begin
            self.serializer.dump(value)
          rescue Timeout::Error => e
            raise e
          rescue => ex
            exc = Dalli::MarshalError.new(ex.message)
            exc.set_backtrace ex.backtrace
            raise exc
          end
        else
          value.to_s
        end
        compressed = false
        set_compress_option = true if options && options[:compress]
        if (@options[:compress] || set_compress_option) && value.bytesize >= @options[:compression_min_size] &&
          (!@options[:compression_max_size] || value.bytesize <= @options[:compression_max_size])
          value = self.compressor.compress(value)
          compressed = true
        end

        flags = 0
        flags |= FLAG_COMPRESSED if compressed
        flags |= FLAG_SERIALIZED if marshalled
        [value, flags]
      end

      def deserialize(value, flags)
        value = self.compressor.decompress(value) if (flags & FLAG_COMPRESSED) != 0
        value = self.serializer.load(value) if (flags & FLAG_SERIALIZED) != 0
        value
      rescue TypeError
        raise if $!.message !~ /needs to have method `_load'|exception class\/object expected|instance of IO needed|incompatible marshal file format/
        raise UnmarshalError, "Unable to unmarshal value: #{$!.message}"
      rescue ArgumentError
        raise if $!.message !~ /undefined class|marshal data too short/
        raise UnmarshalError, "Unable to unmarshal value: #{$!.message}"
      rescue NameError
        raise if $!.message !~ /uninitialized constant/
        raise UnmarshalError, "Unable to unmarshal value: #{$!.message}"
      rescue Zlib::Error
        raise UnmarshalError, "Unable to uncompress value: #{$!.message}"
      end

      def guard_max_value(key, value)
        if value.bytesize <= @options[:value_max_bytes]
          yield
        else
          message = "Value for #{key} over max size: #{@options[:value_max_bytes]} <= #{value.bytesize}"
          raise Dalli::ValueOverMaxSize, message if @options[:error_when_over_max_size]

          Dalli.logger.error "#{message} - this value may be truncated by memcached"
          false
        end
      end

      def sanitize_ttl(ttl)
        ttl_as_i = ttl.to_i
        return ttl_as_i if ttl_as_i <= MAX_ACCEPTABLE_EXPIRATION_INTERVAL
        now = Time.now.to_i
        return ttl_as_i if ttl_as_i > now
        Dalli.logger.debug "Expiration interval (#{ttl_as_i}) too long for Memcached, converting to an expiration timestamp"
        now + ttl_as_i
      end

      def connect
        Dalli.logger.debug { "Dalli::Server#connect #{name}" }

        begin
          @pid = PIDCache.pid
          @sock = if socket_type == :unix
            Dalli::Socket::UNIX.open(hostname, self, options)
          else
            Dalli::Socket::TCP.open(hostname, port, self, options)
          end
          sasl_authentication if need_auth?
          @version = version
          up!
        rescue Dalli::DalliError
          raise
        rescue SystemCallError, Timeout::Error, EOFError, SocketError => e
          failure!(e)
        end
      end

      def parse_hostname(str)
        res = str.match(/\A(\[([\h:]+)\]|[^:]+)(?::(\d+))?(?::(\d+))?\z/)
        raise Dalli::DalliError, "Could not parse hostname #{str}" if res.nil? || res[1] == '[]'
        hostnam = res[2] || res[1]
        if hostnam.start_with?("/")
          socket_type = :unix
          raise Dalli::DalliError, "Could not parse hostname #{str}" if res[4]
          weigh = res[3]
        else
          socket_type = :tcp
          por = res[3] || DEFAULT_PORT
          por = Integer(por)
          weigh = res[4]
        end
        weigh ||= DEFAULT_WEIGHT
        weigh = Integer(weigh)
        return hostnam, por, weigh, socket_type
      end
    end
  end
end
