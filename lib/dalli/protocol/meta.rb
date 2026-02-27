# frozen_string_literal: true
require 'dalli/protocol/base'

module Dalli
  module Protocol
    class Meta < Base
      TERMINATOR = "\r\n"
      ALLOWED_MULTI_OPS = %i[set delete add replace append prepend].freeze

      def close
        super
        @response_processor = nil
      end

      # Start reading key/value pairs from this connection. This is usually called
      # after a series of quiet mg commands. A mn (meta noop) is sent, and the
      # server begins flushing responses for kv pairs that were found.
      #
      # Returns nothing.
      def multi_response_start
        verify_state
        write_noop
        @multi_buffer = +''
        @multi_position = 0
        @inprogress = true
      end

      def multi_response_completed?
        @multi_buffer.nil?
      end

      # Attempt to receive and parse as many key/value pairs as possible from
      # this server. After #multi_response_start, invoke repeatedly whenever
      # this server's socket is readable until #multi_response_completed?.
      #
      # Returns a Hash of kv pairs received.
      def multi_response_nonblock
        raise 'multi_response has completed' if @multi_buffer.nil?

        @multi_buffer << @sock.read_available
        buf = @multi_buffer
        pos = @multi_position
        values = {}

        loop do
          advance, is_terminal, cas, key, value = response_processor.getk_response_from_buffer(buf, pos)

          if advance.zero?
            break
          elsif is_terminal && key.nil?
            @multi_buffer = nil
            @multi_position = nil
            @inprogress = false
            break
          elsif key
            begin
              values[key] = [value, cas]
            rescue DalliError
            end
          end

          pos += advance
        end

        @multi_position = pos if @multi_buffer
        values
      rescue SystemCallError, Timeout::Error, EOFError => e
        failure!(e)
      end

      def multi_response_abort
        @multi_buffer = nil
        @multi_position = nil
        @inprogress = false
        failure!(RuntimeError.new('External timeout'))
      rescue NetworkError
        true
      end

      # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

      private

      def response_processor
        @response_processor ||= ResponseProcessor.new(self)
      end

      # Make deserialize accessible to ResponseProcessor
      public :deserialize

      # Retrieval Commands
      def get(key, options = nil)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, base64: base64)
        write(req)
        response_processor.meta_get_with_value(cache_nils: !!(options && options.is_a?(Hash) && options[:cache_nils]))
      end

      def send_multiget(keys)
        req = +""
        keys.each do |key|
          encoded_key, base64 = KeyRegularizer.encode(key)
          req << RequestFormatter.meta_get(key: encoded_key, return_cas: true, base64: base64, quiet: true)
        end
        write(req)
      end

      # Storage Commands
      def set(key, value, ttl, cas, options)
        write_storage_req(:set, key, value, ttl, cas, options)
        @pending_multi_response ||= multi?
        response_processor.meta_set_with_cas unless multi?
      end

      def add(key, value, ttl, options)
        write_storage_req(:add, key, value, ttl, nil, options)
        @pending_multi_response ||= multi?
        response_processor.meta_set_with_cas unless multi?
      end

      def replace(key, value, ttl, cas, options)
        write_storage_req(:replace, key, value, ttl, cas, options)
        @pending_multi_response ||= multi?
        response_processor.meta_set_with_cas unless multi?
      end

      def append(key, value)
        write_append_prepend_req(:append, key, value)
        @pending_multi_response ||= multi?
        response_processor.meta_set_append_prepend unless multi?
      end

      def prepend(key, value)
        write_append_prepend_req(:prepend, key, value)
        @pending_multi_response ||= multi?
        response_processor.meta_set_append_prepend unless multi?
      end

      # Delete Commands
      def delete(key, cas)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_delete(key: encoded_key, cas: cas, base64: base64, quiet: multi?)
        write(req)
        @pending_multi_response ||= multi?
        response_processor.meta_delete unless multi?
      end

      # Arithmetic Commands
      def decr(key, count, ttl, default)
        decr_incr(false, key, count, ttl, default)
      end

      def incr(key, count, ttl, default)
        decr_incr(true, key, count, ttl, default)
      end

      # Other Commands
      def flush(ttl)
        delay = ttl.to_i
        write(RequestFormatter.flush(delay: delay > 0 ? delay : nil))
        response_processor.flush
      end

      def noop
        write_noop
        response_processor.consume_all_responses_until_mn
      end

      def stats(info = '')
        write(RequestFormatter.stats(info))
        response_processor.stats
      end

      def reset_stats
        write(RequestFormatter.stats('reset'))
        response_processor.reset
      end

      def cas(key)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, value: true, return_cas: true, base64: base64)
        write(req)
        response_processor.meta_get_with_value_and_cas
      end

      def version
        write(RequestFormatter.version)
        response_processor.version
      end

      def touch(key, ttl)
        ttl = sanitize_ttl(ttl)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_get(key: encoded_key, ttl: ttl, value: false, base64: base64)
        write(req)
        response_processor.meta_get_without_value
      end

      def write_noop
        write(RequestFormatter.meta_noop)
      end

      def write_storage_req(mode, key, raw_value, ttl, cas, options)
        (value, bitflags) = serialize(key, raw_value, options)
        ttl = sanitize_ttl(ttl)
        encoded_key, base64 = KeyRegularizer.encode(key)

        guard_max_value(key, value) do
          req = RequestFormatter.meta_set(
            key: encoded_key, value: value, bitflags: bitflags,
            cas: cas, ttl: ttl, mode: mode, base64: base64, quiet: multi?
          )
          req << value << TERMINATOR
          write(req)
        end
      end

      def write_append_prepend_req(mode, key, value)
        encoded_key, base64 = KeyRegularizer.encode(key)
        req = RequestFormatter.meta_set(
          key: encoded_key, value: value, base64: base64,
          mode: mode, quiet: multi?
        )
        req << value << TERMINATOR
        write(req)
      end

      def decr_incr(incr, key, delta, ttl, initial)
        ttl = initial ? sanitize_ttl(ttl) : nil
        encoded_key, base64 = KeyRegularizer.encode(key)
        write(RequestFormatter.meta_arithmetic(
          key: encoded_key, delta: delta, initial: initial,
          incr: incr, ttl: ttl, base64: base64
        ))
        response_processor.decr_incr
      end

      def post_connect
        if @options[:username] || ENV['MEMCACHE_USERNAME']
          raise Dalli::DalliError, "Meta protocol does not support SASL authentication"
        end
        @sock.clear_read_buffer if @sock.respond_to?(:clear_read_buffer)
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

      require_relative 'meta/key_regularizer'
      require_relative 'meta/request_formatter'
      require_relative 'meta/response_processor'
    end
  end
end
