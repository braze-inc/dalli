# frozen_string_literal: true
require_relative 'helper'
require 'dalli/protocol/meta'
require 'dalli/cas/client'

describe 'Dalli Meta Protocol' do
  # Use a dedicated port range for meta protocol tests
  META_PORT = 21500

  def memcached_meta_persistent(port = META_PORT)
    dc = start_and_flush_with_retry(port, '', {protocol: :meta})
    yield dc, port if block_given?
  end

  describe 'basic operations' do
    it 'supports set and get' do
      memcached_meta_persistent do |dc|
        dc.set('meta_key', 'meta_value')
        assert_equal 'meta_value', dc.get('meta_key')
      end
    end

    it 'supports get returning nil for missing keys' do
      memcached_meta_persistent do |dc|
        assert_nil dc.get('nonexistent_key_abc123')
      end
    end

    it 'supports set with TTL' do
      memcached_meta_persistent do |dc|
        dc.set('ttl_key', 'ttl_value', 1)
        assert_equal 'ttl_value', dc.get('ttl_key')
        sleep 1.2
        assert_nil dc.get('ttl_key')
      end
    end

    it 'supports set returning CAS value' do
      memcached_meta_persistent do |dc|
        result = dc.set('cas_test', 'value1')
        assert result.is_a?(Integer)
        assert result > 0
      end
    end

    it 'supports delete' do
      memcached_meta_persistent do |dc|
        dc.set('del_key', 'del_value')
        assert_equal 'del_value', dc.get('del_key')
        assert dc.delete('del_key')
        assert_nil dc.get('del_key')
      end
    end

    it 'supports add' do
      memcached_meta_persistent do |dc|
        dc.delete('add_key') rescue nil
        result = dc.add('add_key', 'add_value')
        assert result
        assert_equal 'add_value', dc.get('add_key')

        result2 = dc.add('add_key', 'other_value')
        assert_equal false, result2
        assert_equal 'add_value', dc.get('add_key')
      end
    end

    it 'supports replace' do
      memcached_meta_persistent do |dc|
        dc.set('rep_key', 'original')
        result = dc.replace('rep_key', 'replaced')
        assert result
        assert_equal 'replaced', dc.get('rep_key')
      end
    end

    it 'supports replace failing on missing key' do
      memcached_meta_persistent do |dc|
        dc.delete('rep_missing') rescue nil
        result = dc.replace('rep_missing', 'value')
        assert_equal false, result
      end
    end
  end

  describe 'counter operations' do
    it 'supports incr' do
      memcached_meta_persistent do |dc|
        dc.set('counter', 10, 0, raw: true)
        result = dc.incr('counter', 5)
        assert_equal 15, result
      end
    end

    it 'supports decr' do
      memcached_meta_persistent do |dc|
        dc.set('counter2', 10, 0, raw: true)
        result = dc.decr('counter2', 3)
        assert_equal 7, result
      end
    end

    it 'supports incr with default' do
      memcached_meta_persistent do |dc|
        dc.delete('new_counter') rescue nil
        result = dc.incr('new_counter', 1, 0, 100)
        assert_equal 100, result
      end
    end

    it 'supports decr with default' do
      memcached_meta_persistent do |dc|
        dc.delete('new_dcounter') rescue nil
        result = dc.decr('new_dcounter', 1, 0, 50)
        assert_equal 50, result
      end
    end

    it 'incr returns nil when key does not exist and no default' do
      memcached_meta_persistent do |dc|
        dc.delete('missing_counter') rescue nil
        result = dc.incr('missing_counter', 1)
        assert_nil result
      end
    end
  end

  describe 'touch' do
    it 'updates expiration on existing key' do
      memcached_meta_persistent do |dc|
        dc.set('touch_key', 'touch_val', 1)
        result = dc.touch('touch_key', 60)
        assert_equal true, result
        sleep 1.2
        assert_equal 'touch_val', dc.get('touch_key')
      end
    end

    it 'returns nil for missing key' do
      memcached_meta_persistent do |dc|
        dc.delete('touch_missing') rescue nil
        result = dc.touch('touch_missing', 60)
        assert_nil result
      end
    end
  end

  describe 'append and prepend' do
    it 'supports append' do
      memcached_meta_persistent do |dc|
        dc.set('append_key', 'hello', 0, raw: true)
        dc.append('append_key', ' world')
        assert_equal 'hello world', dc.get('append_key', raw: true)
      end
    end

    it 'supports prepend' do
      memcached_meta_persistent do |dc|
        dc.set('prepend_key', 'world', 0, raw: true)
        dc.prepend('prepend_key', 'hello ')
        assert_equal 'hello world', dc.get('prepend_key', raw: true)
      end
    end
  end

  describe 'CAS operations' do
    it 'supports cas (compare and swap)' do
      memcached_meta_persistent do |dc|
        dc.set('cas_key', 'original')
        result = dc.cas('cas_key') do |val|
          assert_equal 'original', val
          'updated'
        end
        assert result
        assert_equal 'updated', dc.get('cas_key')
      end
    end

    it 'cas returns nil for missing key' do
      memcached_meta_persistent do |dc|
        dc.delete('cas_missing') rescue nil
        result = dc.cas('cas_missing') { 'value' }
        assert_nil result
      end
    end
  end

  describe 'serialization' do
    it 'handles complex Ruby objects' do
      memcached_meta_persistent do |dc|
        value = {name: 'test', count: 42, nested: [1, 2, 3]}
        dc.set('complex_key', value)
        assert_equal value, dc.get('complex_key')
      end
    end

    it 'handles raw string values' do
      memcached_meta_persistent do |dc|
        dc.set('raw_key', 'raw_value', 0, raw: true)
        assert_equal 'raw_value', dc.get('raw_key', raw: true)
      end
    end

    it 'handles nil values' do
      memcached_meta_persistent do |dc|
        dc.set('nil_key', nil)
        assert_nil dc.get('nil_key')
      end
    end

    it 'handles integer values' do
      memcached_meta_persistent do |dc|
        dc.set('int_key', 42)
        assert_equal 42, dc.get('int_key')
      end
    end
  end

  describe 'multi-get' do
    it 'supports get_multi' do
      memcached_meta_persistent do |dc|
        dc.set('mk1', 'val1')
        dc.set('mk2', 'val2')
        dc.set('mk3', 'val3')

        result = dc.get_multi('mk1', 'mk2', 'mk3')
        assert_equal 'val1', result['mk1']
        assert_equal 'val2', result['mk2']
        assert_equal 'val3', result['mk3']
      end
    end

    it 'omits missing keys from get_multi results' do
      memcached_meta_persistent do |dc|
        dc.set('mgk1', 'val1')
        dc.delete('mgk2') rescue nil

        result = dc.get_multi('mgk1', 'mgk2')
        assert_equal 'val1', result['mgk1']
        refute result.key?('mgk2')
      end
    end

    it 'handles empty key list' do
      memcached_meta_persistent do |dc|
        result = dc.get_multi
        assert_equal({}, result)
      end
    end

    it 'handles get_multi with complex objects' do
      memcached_meta_persistent do |dc|
        dc.set('mgo1', {a: 1})
        dc.set('mgo2', [1, 2, 3])

        result = dc.get_multi('mgo1', 'mgo2')
        assert_equal({a: 1}, result['mgo1'])
        assert_equal [1, 2, 3], result['mgo2']
      end
    end

    it 'handles get_multi with keys requiring base64 encoding' do
      memcached_meta_persistent do |dc|
        unicode_key = +"meta_\xC3\xA9_key"
        unicode_key.force_encoding(Encoding::UTF_8)
        spaced_key = 'meta key with spaces'
        tab_key = "meta\tkey\twith\ttabs"

        dc.set(unicode_key, 'unicode-value')
        dc.set(spaced_key, 'space-value')
        dc.set(tab_key, 'tab-value')

        result = dc.get_multi(unicode_key, spaced_key, tab_key)
        assert_equal 'unicode-value', result[unicode_key]
        assert_equal 'space-value', result[spaced_key]
        assert_equal 'tab-value', result[tab_key]
      end
    end
  end

  describe 'CAS client API' do
    it 'supports get_multi_cas, set_cas, replace_cas, and delete_cas' do
      memcached_meta_persistent do |_, port|
        dc = Dalli::Client.new(
          ["localhost:#{port}", "127.0.0.1:#{port}"],
          protocol: :meta
        )

        dc.set('meta_cas_api_key', 'v1')
        value, cas = dc.get_cas('meta_cas_api_key')
        assert_equal 'v1', value
        assert cas.is_a?(Integer)
        assert cas > 0

        set_cas_result = dc.set_cas('meta_cas_api_key', 'v2', cas)
        assert set_cas_result.is_a?(Integer)
        assert set_cas_result > 0

        replace_cas_result = dc.replace_cas('meta_cas_api_key', 'v3', set_cas_result)
        assert replace_cas_result.is_a?(Integer)
        assert replace_cas_result > 0

        assert_equal true, dc.delete_cas('meta_cas_api_key', replace_cas_result)
        assert_nil dc.get('meta_cas_api_key')

        dc.set('meta_multi_cas_1', 'm1')
        dc.set('meta_multi_cas_2', 'm2')
        multi = dc.get_multi_cas('meta_multi_cas_1', 'meta_multi_cas_2', 'meta_multi_cas_missing')
        assert_equal 'm1', multi['meta_multi_cas_1'][0]
        assert_equal 'm2', multi['meta_multi_cas_2'][0]
        assert multi['meta_multi_cas_1'][1].is_a?(Integer)
        assert multi['meta_multi_cas_2'][1].is_a?(Integer)
        refute multi.key?('meta_multi_cas_missing')
      end
    end
  end

  describe 'multi (quiet) operations' do
    it 'supports pipelined set and delete' do
      memcached_meta_persistent do |dc|
        dc.multi do
          dc.set('mq1', 'val1')
          dc.set('mq2', 'val2')
        end
        assert_equal 'val1', dc.get('mq1')
        assert_equal 'val2', dc.get('mq2')

        dc.multi do
          dc.delete('mq1')
          dc.delete('mq2')
        end
        assert_nil dc.get('mq1')
        assert_nil dc.get('mq2')
      end
    end
  end

  describe 'server info' do
    it 'supports version' do
      memcached_meta_persistent do |dc|
        versions = dc.version
        refute_empty versions
        versions.each_value do |v|
          assert_match(/\d+\.\d+/, v)
        end
      end
    end

    it 'supports stats' do
      memcached_meta_persistent do |dc|
        stats = dc.stats
        refute_empty stats
        stats.each_value do |s|
          assert s.is_a?(Hash)
          assert s.key?('pid')
          assert s.key?('uptime')
        end
      end
    end

    it 'supports flush' do
      memcached_meta_persistent do |dc|
        dc.set('flush_test', 'value')
        dc.flush
        assert_nil dc.get('flush_test')
      end
    end
  end

  describe 'fetch' do
    it 'returns cached value' do
      memcached_meta_persistent do |dc|
        dc.set('fetch_key', 'cached')
        result = dc.fetch('fetch_key') { 'computed' }
        assert_equal 'cached', result
      end
    end

    it 'computes and caches on miss' do
      memcached_meta_persistent do |dc|
        dc.delete('fetch_miss') rescue nil
        result = dc.fetch('fetch_miss') { 'computed' }
        assert_equal 'computed', result
        assert_equal 'computed', dc.get('fetch_miss')
      end
    end
  end

  describe 'cache_nils' do
    it 'supports cache_nils option' do
      memcached_meta_persistent do |dc, port|
        dc_nils = Dalli::Client.new(
          ["localhost:#{port}", "127.0.0.1:#{port}"],
          protocol: :meta, cache_nils: true
        )
        dc_nils.set('nil_cache_key', nil)
        result = dc_nils.fetch('nil_cache_key') { 'fallback' }
        assert_nil result
      end
    end
  end

  describe 'namespace' do
    it 'supports namespaced keys' do
      memcached_meta_persistent do |dc, port|
        dc_ns = Dalli::Client.new(
          ["localhost:#{port}", "127.0.0.1:#{port}"],
          protocol: :meta, namespace: 'test_ns'
        )
        dc_ns.set('nskey', 'nsval')
        assert_equal 'nsval', dc_ns.get('nskey')

        dc_raw = Dalli::Client.new(
          ["localhost:#{port}", "127.0.0.1:#{port}"],
          protocol: :meta
        )
        assert_equal 'nsval', dc_raw.get('test_ns:nskey')
      end
    end
  end

  describe 'error handling' do
    it 'rejects SASL with meta protocol' do
      assert_raises(Dalli::DalliError) do
        dc = Dalli::Client.new('localhost:11211', protocol: :meta, username: 'user', password: 'pass')
        dc.alive!
      end
    end
  end
end
