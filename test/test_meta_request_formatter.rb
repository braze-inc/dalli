# frozen_string_literal: true
require_relative 'helper'
require 'dalli/protocol/meta'

describe 'Dalli::Protocol::Meta::RequestFormatter' do
  let(:fmt) { Dalli::Protocol::Meta::RequestFormatter }

  describe '.meta_get' do
    it 'builds a basic get with value and flags' do
      assert_equal "mg mykey v f\r\n", fmt.meta_get(key: 'mykey')
    end

    it 'omits value flag when value: false' do
      assert_equal "mg mykey\r\n", fmt.meta_get(key: 'mykey', value: false)
    end

    it 'includes cas flag' do
      assert_equal "mg mykey v f c\r\n", fmt.meta_get(key: 'mykey', return_cas: true)
    end

    it 'includes base64 flag' do
      assert_equal "mg mykey v f b\r\n", fmt.meta_get(key: 'mykey', base64: true)
    end

    it 'includes TTL flag' do
      assert_equal "mg mykey v f T300\r\n", fmt.meta_get(key: 'mykey', ttl: 300)
    end

    it 'includes quiet mode flags for multi-get' do
      assert_equal "mg mykey v f c k q s\r\n", fmt.meta_get(key: 'mykey', return_cas: true, quiet: true)
    end

    it 'builds touch command (no value)' do
      assert_equal "mg mykey T60\r\n", fmt.meta_get(key: 'mykey', value: false, ttl: 60)
    end
  end

  describe '.meta_set' do
    it 'builds a set command' do
      result = fmt.meta_set(key: 'mykey', value: 'hello', bitflags: 1, ttl: 300, mode: :set)
      assert_equal "ms mykey 5 c F1 T300 MS\r\n", result
    end

    it 'builds an add command' do
      result = fmt.meta_set(key: 'mykey', value: 'hello', bitflags: 1, ttl: 300, mode: :add)
      assert_equal "ms mykey 5 c F1 T300 ME\r\n", result
    end

    it 'builds a replace command' do
      result = fmt.meta_set(key: 'mykey', value: 'hello', bitflags: 1, ttl: 300, mode: :replace)
      assert_equal "ms mykey 5 c F1 T300 MR\r\n", result
    end

    it 'builds an append command without cas flag' do
      result = fmt.meta_set(key: 'mykey', value: 'data', mode: :append)
      assert_equal "ms mykey 4 MA\r\n", result
    end

    it 'builds a prepend command without cas flag' do
      result = fmt.meta_set(key: 'mykey', value: 'data', mode: :prepend)
      assert_equal "ms mykey 4 MP\r\n", result
    end

    it 'includes CAS value when provided' do
      result = fmt.meta_set(key: 'mykey', value: 'hi', bitflags: 0, cas: 42, ttl: 60, mode: :set)
      assert_equal "ms mykey 2 c F0 C42 T60 MS\r\n", result
    end

    it 'omits CAS when zero' do
      result = fmt.meta_set(key: 'mykey', value: 'hi', bitflags: 0, cas: 0, ttl: 60, mode: :set)
      assert_equal "ms mykey 2 c F0 T60 MS\r\n", result
    end

    it 'includes quiet flag' do
      result = fmt.meta_set(key: 'mykey', value: 'hi', mode: :set, quiet: true)
      assert_equal "ms mykey 2 c MS q\r\n", result
    end

    it 'includes base64 flag' do
      result = fmt.meta_set(key: 'encoded', value: 'x', base64: true, mode: :set)
      assert_equal "ms encoded 1 c b MS\r\n", result
    end
  end

  describe '.meta_delete' do
    it 'builds a basic delete' do
      assert_equal "md mykey\r\n", fmt.meta_delete(key: 'mykey')
    end

    it 'includes CAS value' do
      assert_equal "md mykey C99\r\n", fmt.meta_delete(key: 'mykey', cas: 99)
    end

    it 'includes quiet flag' do
      assert_equal "md mykey q\r\n", fmt.meta_delete(key: 'mykey', quiet: true)
    end

    it 'includes base64 flag' do
      assert_equal "md mykey b\r\n", fmt.meta_delete(key: 'mykey', base64: true)
    end
  end

  describe '.meta_arithmetic' do
    it 'builds an increment command' do
      result = fmt.meta_arithmetic(key: 'cnt', delta: 5, initial: nil, incr: true)
      assert_equal "ma cnt v D5 MI\r\n", result
    end

    it 'builds a decrement command' do
      result = fmt.meta_arithmetic(key: 'cnt', delta: 3, initial: nil, incr: false)
      assert_equal "ma cnt v D3 MD\r\n", result
    end

    it 'includes initial and TTL when initial is provided' do
      result = fmt.meta_arithmetic(key: 'cnt', delta: 1, initial: 100, incr: true, ttl: 60)
      assert_equal "ma cnt v D1 J100 N60 MI\r\n", result
    end

    it 'sets N0 when initial provided but no ttl' do
      result = fmt.meta_arithmetic(key: 'cnt', delta: 1, initial: 10, incr: true)
      assert_equal "ma cnt v D1 J10 N0 MI\r\n", result
    end
  end

  describe '.meta_noop' do
    it 'returns mn command' do
      assert_equal "mn\r\n", fmt.meta_noop
    end
  end

  describe '.version' do
    it 'returns version command' do
      assert_equal "version\r\n", fmt.version
    end
  end

  describe '.flush' do
    it 'returns flush_all without delay' do
      assert_equal "flush_all\r\n", fmt.flush
    end

    it 'returns flush_all with delay' do
      assert_equal "flush_all 5\r\n", fmt.flush(delay: 5)
    end
  end

  describe '.stats' do
    it 'returns stats command' do
      assert_equal "stats\r\n", fmt.stats
    end

    it 'returns stats with argument' do
      assert_equal "stats items\r\n", fmt.stats('items')
    end

    it 'handles empty string argument' do
      assert_equal "stats\r\n", fmt.stats('')
    end
  end
end
