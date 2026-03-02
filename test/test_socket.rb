# frozen_string_literal: true
require_relative 'helper'

class MockSocket
  include Dalli::Socket::InstanceMethods
  attr_accessor :options, :read_results

  def initialize(options = {})
    @options = options
    # @read_results is an array of string "chunks" and other responses
    # (e.g. :wait_readable, :wait_writable) being streamed from the attempted
    # socket read.
    @read_results = []
    @read_index = 0
  end

  def read_nonblock(_count, exception: true)
    result = @read_results[@read_index]
    @read_index += 1
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

  describe '#read_line' do
    it 'returns one CRLF-terminated line' do
      sock.read_results = ["hello\r\n"]
      assert_equal "hello\r\n", sock.read_line
    end

    it 'accumulates chunks until terminator' do
      sock.read_results = ["he", "llo\r", "\nrest"]
      assert_equal "hello\r\n", sock.read_line
      assert_equal "rest", sock.read_from_buffer(4)
    end

    it 'preserves over-read bytes for read_from_buffer' do
      sock.read_results = ["first\r\nsecond"]
      assert_equal "first\r\n", sock.read_line
      assert_equal "second", sock.read_from_buffer(6)
    end

    it 'retries on :wait_readable when IO.select succeeds' do
      sock.read_results = [:wait_readable, "hello\r\n"]
      IO.stubs(:select).with([sock], nil, nil, 1).returns([[sock]])
      assert_equal "hello\r\n", sock.read_line
    end

    it 'raises Timeout::Error on :wait_readable when IO.select times out' do
      sock.read_results = [:wait_readable]
      IO.stubs(:select).with([sock], nil, nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.read_line }
    end

    it 'raises Errno::ECONNRESET when read returns nil' do
      sock.read_results = [nil]
      assert_raises(Errno::ECONNRESET) { sock.read_line }
    end
  end

  describe '#read_from_buffer' do
    it 'consumes bytes already buffered by read_line' do
      sock.read_results = ["abc\r\nXYZ"]
      assert_equal "abc\r\n", sock.read_line
      assert_equal "XYZ", sock.read_from_buffer(3)
    end

    it 'reads exactly requested bytes and preserves remainder' do
      sock.read_results = ["abc", "def"]
      assert_equal "abcde", sock.read_from_buffer(5)
      assert_equal "f", sock.read_from_buffer(1)
    end

    it 'retries on :wait_writable when IO.select succeeds' do
      sock.read_results = [:wait_writable, "hello"]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns([nil, [sock]])
      assert_equal "hello", sock.read_from_buffer(5)
    end

    it 'raises Timeout::Error on :wait_writable when IO.select times out' do
      sock.read_results = [:wait_writable]
      IO.stubs(:select).with(nil, [sock], nil, 1).returns(nil)
      assert_raises(Timeout::Error) { sock.read_from_buffer(5) }
    end

    it 'raises Errno::ECONNRESET when read returns nil' do
      sock.read_results = [nil]
      assert_raises(Errno::ECONNRESET) { sock.read_from_buffer(5) }
    end
  end

  describe '#clear_read_buffer' do
    it 'clears internal buffered bytes' do
      sock.read_results = ["abc\r\nremaining"]
      assert_equal "abc\r\n", sock.read_line
      sock.clear_read_buffer
      sock.read_results = ["new"]
      assert_equal "new", sock.read_from_buffer(3)
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
end
