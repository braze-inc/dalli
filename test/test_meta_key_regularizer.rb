# frozen_string_literal: true
require_relative 'helper'
require 'dalli/protocol/meta'

describe 'Dalli::Protocol::Meta::KeyRegularizer' do
  let(:kr) { Dalli::Protocol::Meta::KeyRegularizer }

  describe '.encode' do
    it 'returns ASCII keys unchanged' do
      key, base64 = kr.encode('simple_key')
      assert_equal 'simple_key', key
      assert_equal false, base64
    end

    it 'base64-encodes keys with whitespace' do
      key, base64 = kr.encode('key with spaces')
      assert_equal true, base64
      refute_match(/\s/, key)
    end

    it 'base64-encodes keys with non-ASCII characters' do
      key, base64 = kr.encode("key\xC3\xA9")
      assert_equal true, base64
      assert key.ascii_only?
    end

    it 'base64-encodes keys with tabs' do
      key, base64 = kr.encode("key\twith\ttabs")
      assert_equal true, base64
    end

    it 'base64-encodes keys with newlines' do
      key, base64 = kr.encode("key\nwith\nnewlines")
      assert_equal true, base64
    end
  end

  describe '.decode' do
    it 'returns non-base64 keys unchanged' do
      assert_equal 'simple_key', kr.decode('simple_key', false)
    end

    it 'decodes base64-encoded keys' do
      original = 'key with spaces'
      encoded, _ = kr.encode(original)
      assert_equal original, kr.decode(encoded, true)
    end

    it 'round-trips non-ASCII keys' do
      original = +"key\xC3\xA9value"
      original.force_encoding(Encoding::UTF_8)
      encoded, base64 = kr.encode(original)
      decoded = kr.decode(encoded, base64)
      assert_equal original, decoded
      assert_equal Encoding::UTF_8, decoded.encoding
    end
  end
end
