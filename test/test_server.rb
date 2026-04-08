# frozen_string_literal: true
require 'ostruct'
require_relative 'helper'

describe Dalli::Server do
  let(:server) { Dalli::Server.new('localhost') }

  describe 'name' do
    it 'returns hostname:port for tcp sockets' do
      s = Dalli::Server.new('localhost:11211')
      assert_equal 'localhost:11211', s.name
    end

    it 'returns hostname for unix sockets' do
      s = Dalli::Server.new('/var/run/memcached/sock')
      assert_equal '/var/run/memcached/sock', s.name
    end

    it 'uses default port in name when not specified' do
      assert_equal 'localhost:11211', server.name
    end
  end

  describe 'initialization defaults' do
    it 'sets default options' do
      assert_equal 60, server.options[:down_retry_delay]
      assert_equal 0.5, server.options[:socket_timeout]
      assert_equal 2, server.options[:socket_max_failures]
      assert_equal 0.01, server.options[:socket_failure_delay]
      assert_equal 1024 * 1024, server.options[:value_max_bytes]
      assert_equal false, server.options[:error_when_over_max_size]
      assert_equal Dalli::Compressor, server.options[:compressor]
      assert_equal 1024, server.options[:compression_min_size]
      assert_equal false, server.options[:compression_max_size]
      assert_equal Marshal, server.options[:serializer]
      assert_nil server.options[:username]
      assert_nil server.options[:password]
      assert_equal true, server.options[:keepalive]
    end

    it 'merges custom options with defaults' do
      s = Dalli::Server.new('localhost', socket_timeout: 2.0, keepalive: false)
      assert_equal 2.0, s.options[:socket_timeout]
      assert_equal false, s.options[:keepalive]
      assert_equal 60, s.options[:down_retry_delay]
    end

    it 'starts with nil sock' do
      assert_nil server.sock
    end
  end

  describe 'serializer and compressor accessors' do
    it 'returns the configured serializer' do
      assert_equal Marshal, server.serializer
    end

    it 'returns the configured compressor' do
      assert_equal Dalli::Compressor, server.compressor
    end

    it 'returns custom serializer' do
      custom = Object.new
      s = Dalli::Server.new('localhost', serializer: custom)
      assert_equal custom, s.serializer
    end

    it 'returns custom compressor' do
      custom = Object.new
      s = Dalli::Server.new('localhost', compressor: custom)
      assert_equal custom, s.compressor
    end
  end

  describe 'close' do
    it 'is a no-op when sock is nil' do
      assert_nil server.sock
      server.close
      assert_nil server.sock
    end

    it 'closes the socket and resets state' do
      mock_sock = mock('socket')
      mock_sock.expects(:close)
      server.instance_variable_set(:@sock, mock_sock)
      server.instance_variable_set(:@pid, Process.pid)

      server.close

      assert_nil server.sock
      assert_nil server.instance_variable_get(:@pid)
      assert_equal false, server.instance_variable_get(:@inprogress)
    end
  end

  describe 'alive?' do
    it 'returns true when sock is present' do
      server.instance_variable_set(:@sock, stub('socket'))
      assert_equal true, server.alive?
    end

    it 'returns false during down_retry_delay period' do
      s = Dalli::Server.new('localhost', down_retry_delay: 60)
      s.instance_variable_set(:@last_down_at, Time.now)
      assert_equal false, s.alive?
    end

    it 'attempts reconnect after down_retry_delay expires' do
      s = Dalli::Server.new('localhost:19999', down_retry_delay: 0)
      s.instance_variable_set(:@last_down_at, Time.now - 1)
      assert_equal false, s.alive?
    end
  end

  describe 'multi_response_completed?' do
    it 'returns true when multi_buffer is nil' do
      server.instance_variable_set(:@multi_buffer, nil)
      assert_equal true, server.multi_response_completed?
    end

    it 'returns false when multi_buffer has content' do
      server.instance_variable_set(:@multi_buffer, 'data')
      assert_equal false, server.multi_response_completed?
    end
  end

  describe 'multi_response_abort' do
    it 'clears multi_buffer and position' do
      server.instance_variable_set(:@multi_buffer, 'data')
      server.instance_variable_set(:@position, 10)
      server.instance_variable_set(:@inprogress, true)

      server.multi_response_abort

      assert_nil server.instance_variable_get(:@multi_buffer)
      assert_nil server.instance_variable_get(:@position)
      assert_equal false, server.instance_variable_get(:@inprogress)
    end
  end

  describe 'request error handling' do
    it 'closes socket on Timeout::Error and re-raises' do
      memcached_persistent do |dc|
        ring = dc.send(:ring)
        s = ring.servers.first
        assert s.alive?

        s.stubs(:verify_state)
        s.stubs(:get).raises(Timeout::Error.new('IO timeout'))

        assert_raises Timeout::Error do
          s.request(:get, 'key')
        end

        assert_nil s.sock
      end
    end

    it 'returns false on MarshalError' do
      memcached_persistent do |dc|
        ring = dc.send(:ring)
        s = ring.servers.first
        assert s.alive?

        s.stubs(:verify_state)
        s.stubs(:set).raises(Dalli::MarshalError.new('cannot dump'))

        with_nil_logger do
          result = s.request(:set, 'key', 'value')
          assert_equal false, result
        end
      end
    end
  end

  describe 'serialize' do
    subject { Dalli::Server.new('127.0.0.1') }

    it 'serializes with Marshal and sets FLAG_SERIALIZED' do
      value, flags = subject.send(:serialize, 'key', 'test_value')
      assert_equal Dalli::Server::FLAG_SERIALIZED, flags & Dalli::Server::FLAG_SERIALIZED
      assert_equal 'test_value', Marshal.load(value)
    end

    it 'does not serialize raw values' do
      value, flags = subject.send(:serialize, 'key', 'raw_value', { raw: true })
      assert_equal 0, flags & Dalli::Server::FLAG_SERIALIZED
      assert_equal 'raw_value', value
    end

    it 'converts raw values to string' do
      value, flags = subject.send(:serialize, 'key', 12345, { raw: true })
      assert_equal '12345', value
      assert_equal 0, flags & Dalli::Server::FLAG_SERIALIZED
    end

    it 'compresses large values when compress is enabled' do
      s = Dalli::Server.new('127.0.0.1', compress: true, compression_min_size: 10)
      large_value = 'x' * 100
      value, flags = s.send(:serialize, 'key', large_value, { raw: true })
      assert_equal Dalli::Server::FLAG_COMPRESSED, flags & Dalli::Server::FLAG_COMPRESSED
      assert_operator value.bytesize, :<, large_value.bytesize
    end

    it 'does not compress values below compression_min_size' do
      s = Dalli::Server.new('127.0.0.1', compress: true, compression_min_size: 1024)
      _value, flags = s.send(:serialize, 'key', 'small', { raw: true })
      assert_equal 0, flags & Dalli::Server::FLAG_COMPRESSED
    end

    it 'does not compress values above compression_max_size' do
      s = Dalli::Server.new('127.0.0.1', compress: true, compression_min_size: 10, compression_max_size: 50)
      large_value = 'x' * 100
      _value, flags = s.send(:serialize, 'key', large_value, { raw: true })
      assert_equal 0, flags & Dalli::Server::FLAG_COMPRESSED
    end

    it 'compresses when per-request :compress option is set' do
      s = Dalli::Server.new('127.0.0.1', compression_min_size: 10)
      large_value = 'x' * 100
      _value, flags = s.send(:serialize, 'key', large_value, { raw: true, compress: true })
      assert_equal Dalli::Server::FLAG_COMPRESSED, flags & Dalli::Server::FLAG_COMPRESSED
    end

    it 'sets both flags when value is serialized and compressed' do
      s = Dalli::Server.new('127.0.0.1', compress: true, compression_min_size: 10)
      large_value = 'x' * 100
      _value, flags = s.send(:serialize, 'key', large_value)
      expected = Dalli::Server::FLAG_SERIALIZED | Dalli::Server::FLAG_COMPRESSED
      assert_equal expected, flags & expected
    end

    it 'wraps serialization errors as MarshalError' do
      assert_raises Dalli::MarshalError do
        subject.send(:serialize, 'key', Proc.new { true })
      end
    end
  end

  describe 'deserialize' do
    subject { Dalli::Server.new('127.0.0.1') }

    it 'returns raw value when no flags set' do
      value = subject.send(:deserialize, 'plain', 0)
      assert_equal 'plain', value
    end

    it 'decompresses compressed values' do
      original = 'test data'
      compressed = Dalli::Compressor.compress(original)
      value = subject.send(:deserialize, compressed, Dalli::Server::FLAG_COMPRESSED)
      assert_equal original, value
    end

    it 'decompresses and deserializes when both flags set' do
      original = { key: 'value' }
      serialized = Marshal.dump(original)
      compressed = Dalli::Compressor.compress(serialized)
      flags = Dalli::Server::FLAG_SERIALIZED | Dalli::Server::FLAG_COMPRESSED
      value = subject.send(:deserialize, compressed, flags)
      assert_equal original, value
    end

    it 'raises UnmarshalError for Zlib decompression errors' do
      assert_raises Dalli::UnmarshalError do
        subject.send(:deserialize, 'not compressed', Dalli::Server::FLAG_COMPRESSED)
      end
    end

    it 'raises UnmarshalError for marshal data too short' do
      assert_raises Dalli::UnmarshalError do
        subject.send(:deserialize, '', Dalli::Server::FLAG_SERIALIZED)
      end
    end
  end

  describe 'verify_state' do
    it 'raises NetworkError when inprogress is true' do
      server.instance_variable_set(:@inprogress, true)
      assert_raises Dalli::NetworkError do
        server.send(:verify_state)
      end
    end

    it 'does nothing when state is clean' do
      server.instance_variable_set(:@inprogress, false)
      server.instance_variable_set(:@pid, nil)
      server.send(:verify_state)
    end

    it 'reconnects when pid changes (fork detection)' do
      server.instance_variable_set(:@pid, -1)
      server.instance_variable_set(:@inprogress, false)
      assert_raises Dalli::NetworkError do
        server.send(:verify_state)
      end
    end
  end

  describe 'failure!' do
    it 'reconnects when fail_count is below max' do
      server.instance_variable_set(:@fail_count, 0)
      assert_raises Dalli::NetworkError do
        server.send(:failure!, RuntimeError.new('test'))
      end
      assert_equal 1, server.instance_variable_get(:@fail_count)
    end

    it 'marks server as down when fail_count reaches max' do
      s = Dalli::Server.new('localhost', socket_max_failures: 1)
      s.instance_variable_set(:@fail_count, 0)
      assert_raises Dalli::NetworkError do
        s.send(:failure!, RuntimeError.new('test'))
      end
    end
  end

  describe 'down! and up!' do
    it 'down! sets last_down_at and raises NetworkError' do
      assert_raises Dalli::NetworkError do
        server.send(:down!)
      end
      refute_nil server.instance_variable_get(:@last_down_at)
      refute_nil server.instance_variable_get(:@down_at)
    end

    it 'up! clears failure state' do
      server.instance_variable_set(:@fail_count, 5)
      server.instance_variable_set(:@down_at, Time.now)
      server.instance_variable_set(:@last_down_at, Time.now)
      server.instance_variable_set(:@msg, 'error')
      server.instance_variable_set(:@error, 'RuntimeError')

      server.send(:up!)

      assert_equal 0, server.instance_variable_get(:@fail_count)
      assert_nil server.instance_variable_get(:@down_at)
      assert_nil server.instance_variable_get(:@last_down_at)
      assert_nil server.instance_variable_get(:@msg)
      assert_nil server.instance_variable_get(:@error)
    end
  end

  describe 'multi?' do
    after do
      Thread.current[:dalli_multi] = nil
    end

    it 'returns true when Thread.current[:dalli_multi] is set' do
      Thread.current[:dalli_multi] = true
      assert_equal true, server.send(:multi?)
    end

    it 'returns nil when not in multi block' do
      assert_nil server.send(:multi?)
    end
  end

  describe 'split' do
    it 'splits 64-bit integers into high and low 32-bit parts' do
      h, l = server.send(:split, 0x100000001)
      assert_equal 1, h
      assert_equal 1, l
    end

    it 'handles zero' do
      h, l = server.send(:split, 0)
      assert_equal 0, h
      assert_equal 0, l
    end

    it 'handles max 32-bit value' do
      h, l = server.send(:split, 0xFFFFFFFF)
      assert_equal 0, h
      assert_equal 0xFFFFFFFF, l
    end
  end

  describe 'need_auth?' do
    it 'returns truthy when username option is set' do
      s = Dalli::Server.new('localhost', username: 'user')
      assert s.send(:need_auth?)
    end

    it 'returns falsey when no credentials configured' do
      old_user = ENV['MEMCACHE_USERNAME']
      ENV['MEMCACHE_USERNAME'] = nil
      refute server.send(:need_auth?)
    ensure
      ENV['MEMCACHE_USERNAME'] = old_user
    end

    it 'returns truthy when MEMCACHE_USERNAME env var is set' do
      old_user = ENV['MEMCACHE_USERNAME']
      ENV['MEMCACHE_USERNAME'] = 'envuser'
      s = Dalli::Server.new('localhost')
      assert s.send(:need_auth?)
    ensure
      ENV['MEMCACHE_USERNAME'] = old_user
    end
  end

  describe 'username and password' do
    it 'returns option values' do
      s = Dalli::Server.new('localhost', username: 'user', password: 'pass')
      assert_equal 'user', s.send(:username)
      assert_equal 'pass', s.send(:password)
    end

    it 'falls back to environment variables' do
      old_user = ENV['MEMCACHE_USERNAME']
      old_pass = ENV['MEMCACHE_PASSWORD']
      ENV['MEMCACHE_USERNAME'] = 'envuser'
      ENV['MEMCACHE_PASSWORD'] = 'envpass'
      s = Dalli::Server.new('localhost')
      assert_equal 'envuser', s.send(:username)
      assert_equal 'envpass', s.send(:password)
    ensure
      ENV['MEMCACHE_USERNAME'] = old_user
      ENV['MEMCACHE_PASSWORD'] = old_pass
    end
  end

  describe 'hostname parsing' do
    it 'handles unix socket with no weight' do
      s = Dalli::Server.new('/var/run/memcached/sock')
      assert_equal '/var/run/memcached/sock', s.hostname
      assert_equal 1, s.weight
      assert_equal :unix, s.socket_type
    end

    it 'handles unix socket with a weight' do
      s = Dalli::Server.new('/var/run/memcached/sock:2')
      assert_equal '/var/run/memcached/sock', s.hostname
      assert_equal 2, s.weight
      assert_equal :unix, s.socket_type
    end

    it 'handles no port or weight' do
      assert_equal 'localhost', server.hostname
      assert_equal 11211, server.port
      assert_equal 1, server.weight
      assert_equal :tcp, server.socket_type
    end

    it 'handles a port, but no weight' do
      s = Dalli::Server.new('localhost:11212')
      assert_equal 'localhost', s.hostname
      assert_equal 11212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles a port and a weight' do
      s = Dalli::Server.new('localhost:11212:2')
      assert_equal 'localhost', s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles ipv4 addresses' do
      s = Dalli::Server.new('127.0.0.1')
      assert_equal '127.0.0.1', s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles ipv6 addresses' do
      s = Dalli::Server.new('[::1]')
      assert_equal '::1', s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles ipv6 addresses with port' do
      s = Dalli::Server.new('[::1]:11212')
      assert_equal '::1', s.hostname
      assert_equal 11212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles ipv6 addresses with port and weight' do
      s = Dalli::Server.new('[::1]:11212:2')
      assert_equal '::1', s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles a FQDN' do
      s = Dalli::Server.new('my.fqdn.com')
      assert_equal 'my.fqdn.com', s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'handles a FQDN with port and weight' do
      s = Dalli::Server.new('my.fqdn.com:11212:2')
      assert_equal 'my.fqdn.com', s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it 'throws an exception if the hostname cannot be parsed' do
      expect(-> { Dalli::Server.new('[]') }).must_raise Dalli::DalliError
      expect(-> { Dalli::Server.new('my.fqdn.com:') }).must_raise Dalli::DalliError
      expect(-> { Dalli::Server.new('my.fqdn.com:11212,:2') }).must_raise Dalli::DalliError
      expect(-> { Dalli::Server.new('my.fqdn.com:11212:abc') }).must_raise Dalli::DalliError
    end
  end

  describe 'ttl translation' do
    it 'does not translate ttls under 30 days' do
      assert_equal 30*24*60*60, server.send(:sanitize_ttl, 30*24*60*60)
    end

    it 'translates ttls over 30 days into timestamps' do
      assert_equal Time.now.to_i + 30*24*60*60+1, server.send(:sanitize_ttl, 30*24*60*60 + 1)
    end

    it 'does not translate ttls which are already timestamps' do
      timestamp_ttl = Time.now.to_i + 60
      assert_equal timestamp_ttl, server.send(:sanitize_ttl, timestamp_ttl)
    end
  end

  describe 'guard_max_value' do
    it 'yields when size is under max' do
      value = OpenStruct.new(:bytesize => 1_048_576)

      yielded = false
      server.send(:guard_max_value, :foo, value) do
        yielded = true
      end

      assert_equal yielded, true
    end

    it 'warns when size is over max' do
      value = OpenStruct.new(:bytesize => 1_048_577)

      Dalli.logger.expects(:error).once.with("Value for foo over max size: 1048576 <= 1048577 - this value may be truncated by memcached")

      server.send(:guard_max_value, :foo, value)
    end

    it 'throws when size is over max and error_over_max_size true' do
      s = Dalli::Server.new('127.0.0.1', :error_when_over_max_size => true)
      value = OpenStruct.new(:bytesize => 1_048_577)

      expect(lambda do
        s.send(:guard_max_value, :foo, value)
      end).must_raise Dalli::ValueOverMaxSize
    end
  end

  describe 'deserialize' do
    subject { Dalli::Server.new('127.0.0.1') }

    it 'uses Marshal as default serializer' do
      assert_equal subject.serializer, Marshal
    end

    it 'deserializes serialized value' do
      value = 'some_value'
      deserialized = subject.send(:deserialize, Marshal.dump(value), Dalli::Server::FLAG_SERIALIZED)
      assert_equal value, deserialized
    end

    it 'raises UnmarshalError for broken data' do
      assert_raises Dalli::UnmarshalError do
        subject.send(:deserialize, :not_marshaled_value, Dalli::Server::FLAG_SERIALIZED)
      end
    end

    describe 'custom serializer' do
      let(:serializer) { Minitest::Mock.new }
      subject { Dalli::Server.new('127.0.0.1', serializer: serializer) }

      it 'uses custom serializer' do
        assert subject.serializer === serializer
      end

      it 'reraises general NameError' do
        serializer.expect(:load, nil) do
          raise NameError, 'ddd'
        end
        assert_raises NameError do
          subject.send(:deserialize, :some_value, Dalli::Server::FLAG_SERIALIZED)
        end
      end

      it 'raises UnmarshalError on uninitialized constant' do
        serializer.expect(:load, nil) do
          raise NameError, 'uninitialized constant Ddd'
        end
        assert_raises Dalli::UnmarshalError do
          subject.send(:deserialize, :some_value, Dalli::Server::FLAG_SERIALIZED)
        end
      end

      it 'reraises general ArgumentError' do
        serializer.expect(:load, nil) do
          raise ArgumentError, 'ddd'
        end
        assert_raises ArgumentError do
          subject.send(:deserialize, :some_value, Dalli::Server::FLAG_SERIALIZED)
        end
      end

      it 'raises UnmarshalError on undefined class' do
        serializer.expect(:load, nil) do
          raise ArgumentError, 'undefined class Ddd'
        end
        assert_raises Dalli::UnmarshalError do
          subject.send(:deserialize, :some_value, Dalli::Server::FLAG_SERIALIZED)
        end
      end
    end
  end
end
