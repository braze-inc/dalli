# frozen_string_literal: true
require 'dalli/protocol/base'

module Dalli
  class Server < Protocol::Base
    ALLOWED_MULTI_OPS = %i[set setq delete deleteq add addq replace replaceq].freeze

    # Start reading key/value pairs from this connection. This is usually called
    # after a series of GETKQ commands. A NOOP is sent, and the server begins
    # flushing responses for kv pairs that were found.
    #
    # Returns nothing.
    def multi_response_start
      verify_state
      write_noop
      @multi_buffer = String.new('')
      @position = 0
      @inprogress = true
    end

    # Did the last call to #multi_response_start complete successfully?
    def multi_response_completed?
      @multi_buffer.nil?
    end

    # Attempt to receive and parse as many key/value pairs as possible
    # from this server. After #multi_response_start, this should be invoked
    # repeatedly whenever this server's socket is readable until
    # #multi_response_completed?.
    #
    # Returns a Hash of kv pairs received.
    def multi_response_nonblock
      raise 'multi_response has completed' if @multi_buffer.nil?

      @multi_buffer << @sock.read_available
      buf = @multi_buffer
      pos = @position
      values = {}

      while buf.bytesize - pos >= 24
        header = buf.slice(pos, 24)
        (key_length, _, body_length, cas) = header.unpack(KV_HEADER)

        if key_length == 0
          # all done!
          @multi_buffer = nil
          @position = nil
          @inprogress = false
          break

        elsif buf.bytesize - pos >= 24 + body_length
          flags = buf.slice(pos + 24, 4).unpack1('N')
          key = buf.slice(pos + 24 + 4, key_length)
          value = buf.slice(pos + 24 + 4 + key_length, body_length - key_length - 4) if body_length - key_length - 4 > 0

          pos = pos + 24 + body_length

          begin
            values[key] = [deserialize(value, flags), cas]
          rescue DalliError
          end

        else
          # not enough data yet, wait for more
          break
        end
      end
      @position = pos

      values
    rescue SystemCallError, Timeout::Error, EOFError => e
      failure!(e)
    end

    # Abort an earlier #multi_response_start. Used to signal an external
    # timeout. The underlying socket is disconnected, and the exception is
    # swallowed.
    #
    # Returns nothing.
    def multi_response_abort
      @multi_buffer = nil
      @position = nil
      @inprogress = false
      failure!(RuntimeError.new('External timeout'))
    rescue NetworkError
      true
    end

    # NOTE: Additional public methods should be overridden in Dalli::Threadsafe

    private

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

    def get(key, options=nil)
      req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
      write(req)
      generic_response(true, !!(options && options.is_a?(Hash) && options[:cache_nils]))
    end

    def send_multiget(keys)
      req = +""
      keys.each do |key|
        req << [REQUEST, OPCODES[:getkq], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:getkq])
      end
      write(req)
    end

    def set(key, value, ttl, cas, options)
      (value, flags) = serialize(key, value, options)
      ttl = sanitize_ttl(ttl)

      guard_max_value(key, value) do
        req = [REQUEST, OPCODES[multi? ? :setq : :set], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, cas, flags, ttl, key, value].pack(FORMAT[:set])
        write(req)
        @pending_multi_response ||= multi?
        cas_response unless multi?
      end
    end

    def add(key, value, ttl, options)
      (value, flags) = serialize(key, value, options)
      ttl = sanitize_ttl(ttl)

      guard_max_value(key, value) do
        req = [REQUEST, OPCODES[multi? ? :addq : :add], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, 0, flags, ttl, key, value].pack(FORMAT[:add])
        write(req)
        @pending_multi_response ||= multi?
        cas_response unless multi?
      end
    end

    def replace(key, value, ttl, cas, options)
      (value, flags) = serialize(key, value, options)
      ttl = sanitize_ttl(ttl)

      guard_max_value(key, value) do
        req = [REQUEST, OPCODES[multi? ? :replaceq : :replace], key.bytesize, 8, 0, 0, value.bytesize + key.bytesize + 8, 0, cas, flags, ttl, key, value].pack(FORMAT[:replace])
        write(req)
        @pending_multi_response ||= multi?
        cas_response unless multi?
      end
    end

    def delete(key, cas)
      req = [REQUEST, OPCODES[multi? ? :deleteq : :delete], key.bytesize, 0, 0, 0, key.bytesize, 0, cas, key].pack(FORMAT[:delete])
      write(req)
      @pending_multi_response ||= multi?
      generic_response unless multi?
    end

    def flush(ttl)
      req = [REQUEST, OPCODES[:flush], 0, 4, 0, 0, 4, 0, 0, 0].pack(FORMAT[:flush])
      write(req)
      generic_response
    end

    def decr_incr(opcode, key, count, ttl, default)
      expiry = default ? sanitize_ttl(ttl) : 0xFFFFFFFF
      default ||= 0
      (h, l) = split(count)
      (dh, dl) = split(default)
      req = [REQUEST, OPCODES[opcode], key.bytesize, 20, 0, 0, key.bytesize + 20, 0, 0, h, l, dh, dl, expiry, key].pack(FORMAT[opcode])
      write(req)
      body = generic_response
      body ? body.unpack1('Q>') : body
    end

    def decr(key, count, ttl, default)
      decr_incr :decr, key, count, ttl, default
    end

    def incr(key, count, ttl, default)
      decr_incr :incr, key, count, ttl, default
    end

    def write_append_prepend(opcode, key, value)
      write_generic [REQUEST, OPCODES[opcode], key.bytesize, 0, 0, 0, value.bytesize + key.bytesize, 0, 0, key, value].pack(FORMAT[opcode])
    end

    def write_generic(bytes)
      write(bytes)
      generic_response
    end

    def write_noop
      req = [REQUEST, OPCODES[:noop], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)
    end

    # Noop is a keepalive operation but also used to demarcate the end of a set of pipelined commands.
    # We need to read all the responses at once.
    def noop
      write_noop
      flush_response
    end

    def append(key, value)
      write_append_prepend :append, key, value
    end

    def prepend(key, value)
      write_append_prepend :prepend, key, value
    end

    def stats(info='')
      req = [REQUEST, OPCODES[:stat], info.bytesize, 0, 0, 0, info.bytesize, 0, 0, info].pack(FORMAT[:stat])
      write(req)
      keyvalue_response
    end

    def reset_stats
      write_generic [REQUEST, OPCODES[:stat], 'reset'.bytesize, 0, 0, 0, 'reset'.bytesize, 0, 0, 'reset'].pack(FORMAT[:stat])
    end

    def cas(key)
      req = [REQUEST, OPCODES[:get], key.bytesize, 0, 0, 0, key.bytesize, 0, 0, key].pack(FORMAT[:get])
      write(req)
      data_cas_response
    end

    def version
      write_generic [REQUEST, OPCODES[:version], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
    end

    def touch(key, ttl)
      ttl = sanitize_ttl(ttl)
      write_generic [REQUEST, OPCODES[:touch], key.bytesize, 4, 0, 0, key.bytesize + 4, 0, 0, ttl, key].pack(FORMAT[:touch])
    end

    def data_cas_response
      (extras, _, status, count, _, cas) = read_header.unpack(CAS_HEADER)
      data = read(count) if count > 0
      if status == 1
        nil
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        flags = data[0...extras].unpack1('N')
        value = data[extras..-1]
        data = deserialize(value, flags)
      end
      [data, cas]
    end

    CAS_HEADER = '@4CCnNNQ'
    NORMAL_HEADER = '@4CCnN'
    KV_HEADER = '@2n@6nN@16Q'

    def generic_response(unpack=false, cache_nils=false)
      (extras, _, status, count) = read_header.unpack(NORMAL_HEADER)
      data = read(count) if count > 0
      if status == 1
        cache_nils ? NOT_FOUND : nil
      elsif status == 2 || status == 5
        false # Not stored, normal status for add operation
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      elsif data
        flags = data[0...extras].unpack1('N')
        value = data[extras..-1]
        unpack ? deserialize(value, flags) : value
      else
        true
      end
    end

    def cas_response
      (_, _, status, count, _, cas) = read_header.unpack(CAS_HEADER)
      read(count) if count > 0
      if status == 1
        nil
      elsif status == 2 || status == 5
        false # Not stored, normal status for add operation
      elsif status != 0
        raise Dalli::DalliError, "Response error #{status}: #{RESPONSE_CODES[status]}"
      else
        cas
      end
    end

    def keyvalue_response
      hash = {}
      loop do
        (key_length, _, body_length, _) = read_header.unpack(KV_HEADER)
        return hash if key_length == 0
        key = read(key_length)
        value = read(body_length - key_length) if body_length - key_length > 0
        hash[key] = value
      end
    end

    def flush_response
      loop do
        (key_length, status, body_length, _) = read_header.unpack(KV_HEADER)
        return if key_length == 0 && status == 0
        read(body_length) if body_length > 0
      end
    end

    def read_header
      read(24) || raise(Dalli::NetworkError, 'No response')
    end

    def split(n)
      [n >> 32, 0xFFFFFFFF & n]
    end

    REQUEST = 0x80
    RESPONSE = 0x81

    RESPONSE_CODES = {
      0 => 'No error',
      1 => 'Key not found',
      2 => 'Key exists',
      3 => 'Value too large',
      4 => 'Invalid arguments',
      5 => 'Item not stored',
      6 => 'Incr/decr on a non-numeric value',
      7 => 'The vbucket belongs to another server',
      8 => 'Authentication error',
      9 => 'Authentication continue',
      0x20 => 'Authentication required',
      0x81 => 'Unknown command',
      0x82 => 'Out of memory',
      0x83 => 'Not supported',
      0x84 => 'Internal error',
      0x85 => 'Busy',
      0x86 => 'Temporary failure'
    }

    OPCODES = {
      :get => 0x00,
      :set => 0x01,
      :add => 0x02,
      :replace => 0x03,
      :delete => 0x04,
      :incr => 0x05,
      :decr => 0x06,
      :flush => 0x08,
      :noop => 0x0A,
      :version => 0x0B,
      :getkq => 0x0D,
      :append => 0x0E,
      :prepend => 0x0F,
      :stat => 0x10,
      :setq => 0x11,
      :addq => 0x12,
      :replaceq => 0x13,
      :deleteq => 0x14,
      :incrq => 0x15,
      :decrq => 0x16,
      :auth_negotiation => 0x20,
      :auth_request => 0x21,
      :auth_continue => 0x22,
      :touch => 0x1C,
    }

    HEADER = "CCnCCnNNQ"
    OP_FORMAT = {
      :get => 'a*',
      :set => 'NNa*a*',
      :add => 'NNa*a*',
      :replace => 'NNa*a*',
      :delete => 'a*',
      :incr => 'NNNNNa*',
      :decr => 'NNNNNa*',
      :flush => 'N',
      :noop => '',
      :getkq => 'a*',
      :version => '',
      :stat => 'a*',
      :append => 'a*a*',
      :prepend => 'a*a*',
      :auth_request => 'a*a*',
      :auth_continue => 'a*a*',
      :touch => 'Na*',
    }
    FORMAT = OP_FORMAT.inject({}) { |memo, (k, v)| memo[k] = HEADER + v; memo }


    #######
    # SASL authentication support for NorthScale
    #######

    def need_auth?
      @options[:username] || ENV['MEMCACHE_USERNAME']
    end

    def username
      @options[:username] || ENV['MEMCACHE_USERNAME']
    end

    def password
      @options[:password] || ENV['MEMCACHE_PASSWORD']
    end

    def sasl_authentication
      Dalli.logger.info { "Dalli/SASL authenticating as #{username}" }

      # negotiate
      req = [REQUEST, OPCODES[:auth_negotiation], 0, 0, 0, 0, 0, 0, 0].pack(FORMAT[:noop])
      write(req)

      (extras, _type, status, count) = read_header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      content = read(count).gsub(/\u0000/, ' ')
      return (Dalli.logger.debug("Authentication not required/supported by server")) if status == 0x81
      mechanisms = content.split(' ')
      raise NotImplementedError, "Dalli only supports the PLAIN authentication mechanism" if !mechanisms.include?('PLAIN')

      # request
      mechanism = 'PLAIN'
      msg = "\x0#{username}\x0#{password}"
      req = [REQUEST, OPCODES[:auth_request], mechanism.bytesize, 0, 0, 0, mechanism.bytesize + msg.bytesize, 0, 0, mechanism, msg].pack(FORMAT[:auth_request])
      write(req)

      (extras, _type, status, count) = read_header.unpack(NORMAL_HEADER)
      raise Dalli::NetworkError, "Unexpected message format: #{extras} #{count}" unless extras == 0 && count > 0
      content = read(count)
      return Dalli.logger.info("Dalli/SASL: #{content}") if status == 0

      raise Dalli::DalliError, "Error authenticating: #{status}" unless status == 0x21
      raise NotImplementedError, "No two-step authentication mechanisms supported"
    end
  end
end
