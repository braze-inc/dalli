# frozen_string_literal: true
require_relative 'helper'
require 'dalli/protocol/meta'

describe 'Dalli::Protocol::Meta::ResponseProcessor' do
  # A minimal mock server that provides sock and deserialize for ResponseProcessor
  class MockMetaServer
    attr_reader :sock

    def initialize(response_data)
      @sock = MockMetaSocket.new(response_data)
    end

    def deserialize(value, flags)
      if flags && (flags & 0x1) != 0
        Marshal.load(value)
      else
        value
      end
    end
  end

  class MockMetaSocket
    def initialize(data)
      @data = +data
    end

    def read_line
      idx = @data.index("\r\n")
      return nil unless idx
      @data.slice!(0, idx + 2)
    end

    def read_from_buffer(count)
      @data.slice!(0, count)
    end

    def read_available
      result = @data.dup
      @data.clear
      result
    end
  end

  def build_processor(response_str)
    server = MockMetaServer.new(response_str)
    Dalli::Protocol::Meta::ResponseProcessor.new(server)
  end

  describe '#meta_get_with_value' do
    it 'returns value on VA response' do
      proc = build_processor("VA 5 f0\r\nhello\r\n")
      assert_equal 'hello', proc.meta_get_with_value
    end

    it 'returns nil on EN (not found)' do
      proc = build_processor("EN\r\n")
      assert_nil proc.meta_get_with_value
    end

    it 'returns NOT_FOUND sentinel when cache_nils is true' do
      proc = build_processor("EN\r\n")
      result = proc.meta_get_with_value(cache_nils: true)
      assert_equal Dalli::Protocol::Base::NOT_FOUND, result
    end

    it 'returns true on HD (header only, e.g. touch)' do
      proc = build_processor("HD\r\n")
      assert_equal true, proc.meta_get_with_value
    end
  end

  describe '#meta_get_with_value_and_cas' do
    it 'returns [value, cas] on VA response' do
      proc = build_processor("VA 3 f0 c42\r\nfoo\r\n")
      value, cas = proc.meta_get_with_value_and_cas
      assert_equal 'foo', value
      assert_equal 42, cas
    end

    it 'returns [nil, 0] on EN' do
      proc = build_processor("EN\r\n")
      value, cas = proc.meta_get_with_value_and_cas
      assert_nil value
      assert_equal 0, cas
    end
  end

  describe '#meta_get_without_value' do
    it 'returns true on HD' do
      proc = build_processor("HD\r\n")
      assert_equal true, proc.meta_get_without_value
    end

    it 'returns nil on EN' do
      proc = build_processor("EN\r\n")
      assert_nil proc.meta_get_without_value
    end
  end

  describe '#meta_set_with_cas' do
    it 'returns CAS on HD' do
      proc = build_processor("HD c123\r\n")
      assert_equal 123, proc.meta_set_with_cas
    end

    it 'returns false on NS (not stored)' do
      proc = build_processor("NS\r\n")
      assert_equal false, proc.meta_set_with_cas
    end

    it 'returns false on NF (not found)' do
      proc = build_processor("NF\r\n")
      assert_equal false, proc.meta_set_with_cas
    end

    it 'returns false on EX (exists / CAS conflict)' do
      proc = build_processor("EX\r\n")
      assert_equal false, proc.meta_set_with_cas
    end

    it 'raises DalliError on unexpected response' do
      proc = build_processor("SERVER_ERROR out of memory\r\n")
      assert_raises(Dalli::DalliError) { proc.meta_set_with_cas }
    end
  end

  describe '#meta_delete' do
    it 'returns true on HD' do
      proc = build_processor("HD\r\n")
      assert_equal true, proc.meta_delete
    end

    it 'returns false on NF' do
      proc = build_processor("NF\r\n")
      assert_equal false, proc.meta_delete
    end

    it 'raises DalliError on unexpected response' do
      proc = build_processor("SERVER_ERROR out of memory\r\n")
      assert_raises(Dalli::DalliError) { proc.meta_delete }
    end
  end

  describe '#decr_incr' do
    it 'returns integer value on VA' do
      proc = build_processor("VA 2\r\n42\r\n")
      assert_equal 42, proc.decr_incr
    end

    it 'returns nil on NF' do
      proc = build_processor("NF\r\n")
      assert_nil proc.decr_incr
    end

    it 'returns false on NS' do
      proc = build_processor("NS\r\n")
      assert_equal false, proc.decr_incr
    end
  end

  describe '#version' do
    it 'parses version response' do
      proc = build_processor("VERSION 1.6.40\r\n")
      assert_equal '1.6.40', proc.version
    end
  end

  describe '#flush' do
    it 'returns true on OK' do
      proc = build_processor("OK\r\n")
      assert_equal true, proc.flush
    end
  end

  describe '#stats' do
    it 'parses multiple stat lines' do
      data = "STAT pid 12345\r\nSTAT uptime 100\r\nEND\r\n"
      proc = build_processor(data)
      result = proc.stats
      assert_equal '12345', result['pid']
      assert_equal '100', result['uptime']
    end
  end

  describe '#consume_all_responses_until_mn' do
    it 'consumes responses until MN' do
      data = "HD c1\r\nHD c2\r\nMN\r\n"
      proc = build_processor(data)
      assert_equal true, proc.consume_all_responses_until_mn
    end
  end

  describe 'error handling' do
    it 'raises DalliError on unexpected response' do
      proc = build_processor("UNKNOWN\r\n")
      assert_raises(Dalli::DalliError) { proc.meta_get_with_value }
    end

    it 'raises DalliError on SERVER_ERROR' do
      proc = build_processor("SERVER_ERROR out of memory\r\n")
      assert_raises(Dalli::DalliError) { proc.meta_get_with_value }
    end
  end
end
