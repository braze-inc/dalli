# frozen_string_literal: true
require_relative 'helper'

class MockSocket
  include Dalli::Socket::InstanceMethods
  attr_accessor :options, :read_results, :write_results

  def initialize(options = {})
    @options = options
    @read_results = []
    @write_results = []
    @read_index = 0
    @write_index = 0
  end

  def read_nonblock(_count, exception: true)
    result = @read_results[@read_index]
    @read_index += 1
    result
  end

  def write_nonblock(_bytes, exception: true)
    result = @write_results[@write_index]
    @write_index += 1
    result
  end
end

describe 'Dalli::Socket::InstanceMethods' do
  let(:sock) { MockSocket.new(socket_timeout: 1) }

  describe '#readfull' do
    it 'reads the exact number of bytes requested' do
      sock.read_results = ["hello"]
      assert_equal "hello", sock.readfull(5)
    end

    it 'accumulates data across multiple reads' do
      sock.read_results = ["he", "llo"]
      assert_equal "hello", sock.readfull(5)
    end

    it 'retries on :wait_readable when IO.select succeeds' do
      sock.read_results = [:wait_readable, "hello"]
      IO.stubs(:select).with([sock], nil, nil, 1).returns([[sock]])
      assert_equal "hello", sock.readfull(5)
    end

    it 'retries on :wait_writable when IO.select succeeds' do
      sock.read_results = [:wait_writable, "hello"]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns([nil, [sock]])
      assert_equal "hello", sock.readfull(5)
    end

    it 'raises Timeout::Error on :wait_readable when IO.select times out' do
      sock.read_results = [:wait_readable]
      IO.stubs(:select).with([sock], nil, nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.readfull(5) }
    end

    it 'raises Timeout::Error on :wait_writable when IO.select times out' do
      sock.read_results = [:wait_writable]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.readfull(5) }
    end

    it 'raises Errno::ECONNRESET when read returns nil' do
      sock.read_results = [nil]
      assert_raises(Errno::ECONNRESET) { sock.readfull(5) }
    end

    describe 'with credentials' do
      let(:sock) { MockSocket.new(socket_timeout: 1, username: 'admin', password: 'secret') }

      it 'excludes credentials from Timeout::Error message' do
        sock.read_results = [:wait_readable]
        IO.stubs(:select).with([sock], nil, nil, 1).returns(nil)
        error = assert_raises(Timeout::Error) { sock.readfull(5) }
        refute_match(/admin/, error.message)
        refute_match(/secret/, error.message)
      end

      it 'excludes credentials from Errno::ECONNRESET message' do
        sock.read_results = [nil]
        error = assert_raises(Errno::ECONNRESET) { sock.readfull(5) }
        refute_match(/admin/, error.message)
        refute_match(/secret/, error.message)
      end
    end
  end

  describe '#writefull' do
    it 'writes all bytes in a single call' do
      sock.write_results = [5]
      assert_equal 5, sock.writefull("hello")
    end

    it 'handles partial writes across multiple calls' do
      sock.write_results = [2, 3]
      assert_equal 5, sock.writefull("hello")
    end

    it 'retries on :wait_writable when IO.select succeeds' do
      sock.write_results = [:wait_writable, 5]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns([nil, [sock]])
      assert_equal 5, sock.writefull("hello")
    end

    it 'retries on :wait_readable when IO.select succeeds' do
      sock.write_results = [:wait_readable, 5]
      IO.stubs(:select).with([sock], nil, nil, 1).returns([[sock]])
      assert_equal 5, sock.writefull("hello")
    end

    it 'raises Timeout::Error on :wait_writable when IO.select times out' do
      sock.write_results = [:wait_writable]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.writefull("hello") }
    end

    it 'raises Timeout::Error on :wait_readable when IO.select times out' do
      sock.write_results = [:wait_readable]
      IO.stubs(:select).with([sock], nil, nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.writefull("hello") }
    end

    it 'delivers all bytes through a real socket pair' do
      s1, s2 = Socket.pair(:UNIX, :STREAM, 0)
      s1.extend(Dalli::Socket::InstanceMethods)
      def s1.options; { socket_timeout: 5 }; end

      data = "hello world"
      result = s1.writefull(data)
      s1.close

      assert_equal data.bytesize, result
      assert_equal data, s2.read
    ensure
      s1&.close rescue nil
      s2&.close rescue nil
    end

    describe 'with credentials' do
      let(:sock) { MockSocket.new(socket_timeout: 1, username: 'admin', password: 'secret') }

      it 'excludes credentials from Timeout::Error message' do
        sock.write_results = [:wait_writable]
        IO.stubs(:select).with(nil, [sock], nil, 1).returns(nil)
        error = assert_raises(Timeout::Error) { sock.writefull("hello") }
        refute_match(/admin/, error.message)
        refute_match(/secret/, error.message)
      end
    end
  end

  describe '#read_available' do
    it 'reads all available data until :wait_readable' do
      sock.read_results = ["he", "llo", :wait_readable]
      assert_equal "hello", sock.read_available
    end

    it 'returns empty string when immediately :wait_readable' do
      sock.read_results = [:wait_readable]
      assert_equal "", sock.read_available
    end

    it 'stops reading on :wait_writable' do
      sock.read_results = ["data", :wait_writable]
      assert_equal "data", sock.read_available
    end

    it 'raises Errno::ECONNRESET when read returns nil' do
      sock.read_results = [nil]
      assert_raises(Errno::ECONNRESET) { sock.read_available }
    end

    it 'raises Errno::ECONNRESET after partial read when read returns nil' do
      sock.read_results = ["partial", nil]
      assert_raises(Errno::ECONNRESET) { sock.read_available }
    end

    describe 'with credentials' do
      let(:sock) { MockSocket.new(socket_timeout: 1, username: 'admin', password: 'secret') }

      it 'excludes credentials from Errno::ECONNRESET message' do
        sock.read_results = [nil]
        error = assert_raises(Errno::ECONNRESET) { sock.read_available }
        refute_match(/admin/, error.message)
        refute_match(/secret/, error.message)
      end
    end
  end

  describe '#safe_options' do
    it 'filters out :username and :password' do
      sock = MockSocket.new(host: 'localhost', port: 11211, username: 'admin', password: 'secret')
      assert_equal({host: 'localhost', port: 11211}, sock.safe_options)
    end

    it 'returns all options when no credentials are present' do
      sock = MockSocket.new(host: 'localhost', port: 11211)
      assert_equal({host: 'localhost', port: 11211}, sock.safe_options)
    end
  end
end

describe 'Dalli::Socket::TCP' do
  before do
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
  end

  after do
    @sock&.close
    @server&.close
  end

  it 'sets TCP_NODELAY on the socket' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5)
    assert @sock.getsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY).bool
  end

  it 'enables SO_KEEPALIVE when keepalive option is true' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5, keepalive: true)
    assert @sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE).bool
  end

  it 'does not enable SO_KEEPALIVE by default' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5)
    refute @sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE).bool
  end

  it 'sets SO_RCVBUF when rcvbuf option is provided' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5, rcvbuf: 65536)
    # Kernel may round up the requested value, so assert >=
    assert_operator @sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVBUF).int, :>=, 65536
  end

  it 'sets SO_SNDBUF when sndbuf option is provided' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5, sndbuf: 65536)
    assert_operator @sock.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDBUF).int, :>=, 65536
  end

  it 'stores host, port, and options on the socket' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'srv', socket_timeout: 5, keepalive: true)
    expected = { host: '127.0.0.1', port: @port, socket_timeout: 5, keepalive: true }
    assert_equal expected, @sock.options
  end

  it 'assigns the server reference' do
    @sock = Dalli::Socket::TCP.open('127.0.0.1', @port, 'my_server', socket_timeout: 5)
    assert_equal 'my_server', @sock.server
  end

  it 'raises SocketError for unresolvable hostname' do
    assert_raises(SocketError) do
      Dalli::Socket::TCP.open('this-host-does-not-exist.invalid', 11211, 'srv', socket_timeout: 1)
    end
  end

  it 'includes hostname in SocketError message for unresolvable host' do
    error = assert_raises(SocketError) do
      Dalli::Socket::TCP.open('this-host-does-not-exist.invalid', 11211, 'srv', socket_timeout: 1)
    end
    assert_match(/this-host-does-not-exist\.invalid/, error.message)
  end
end

describe 'Dalli::Socket::UNIX' do
  before do
    @tmpfile = Tempfile.new('dalli_socket_test')
    @path = @tmpfile.path
    @tmpfile.close
    @tmpfile.unlink
    @server = UNIXServer.new(@path)
  end

  after do
    @sock&.close
    @server&.close
    File.delete(@path) if File.exist?(@path)
  end

  it 'returns a connected UNIX socket' do
    @sock = Dalli::Socket::UNIX.open(@path, 'srv', socket_timeout: 5)
    assert_kind_of Dalli::Socket::UNIX, @sock
    refute @sock.closed?
  end

  it 'stores path and options on the socket' do
    @sock = Dalli::Socket::UNIX.open(@path, 'srv', socket_timeout: 5)
    expected = { path: @path, socket_timeout: 5 }
    assert_equal expected, @sock.options
  end

  it 'assigns the server reference' do
    @sock = Dalli::Socket::UNIX.open(@path, 'my_server', socket_timeout: 5)
    assert_equal 'my_server', @sock.server
  end

  it 'raises Errno::ENOENT for non-existent socket path' do
    assert_raises(Errno::ENOENT) do
      Dalli::Socket::UNIX.open('/tmp/nonexistent_dalli_test_socket', 'srv', socket_timeout: 1)
    end
  end
end
