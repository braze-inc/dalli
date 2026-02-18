# frozen_string_literal: true
require_relative 'helper'

describe 'Ring' do

  describe 'a ring of servers' do

    it "have the continuum sorted by value" do
      servers = [stub(:name => "localhost:11211", :weight => 1),
                 stub(:name => "localhost:9500", :weight => 1)]
      ring = Dalli::Ring.new(servers, {})
      previous_value = 0
      ring.continuum.each do |entry|
        assert entry.value > previous_value
        previous_value = entry.value
      end
    end

    it 'raise when no servers are available/defined' do
      ring = Dalli::Ring.new([], {})
      assert_raises Dalli::RingError, :message => "No server available" do
        ring.server_for_key('test')
      end
    end

    describe 'containing only a single server' do
      it "raise correctly when it's not alive" do
        servers = [
          Dalli::Server.new("localhost:12345"),
        ]
        ring = Dalli::Ring.new(servers, {})
        assert_raises Dalli::RingError, :message => "No server available" do
          ring.server_for_key('test')
        end
      end

      it "return the server when it's alive" do
        servers = [
          Dalli::Server.new("localhost:19191"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached(19191) do |mc|
          ring = mc.send(:ring)
          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    describe 'containing multiple servers' do
      it "raise correctly when no server is alive" do
        servers = [
          Dalli::Server.new("localhost:12345"),
          Dalli::Server.new("localhost:12346"),
        ]
        ring = Dalli::Ring.new(servers, {})
        assert_raises Dalli::RingError, :message => "No server available" do
          ring.server_for_key('test')
        end
      end

      it "return an alive server when at least one is alive" do
        servers = [
          Dalli::Server.new("localhost:12346"),
          Dalli::Server.new("localhost:19191"),
        ]
        ring = Dalli::Ring.new(servers, {})
        memcached(19191) do |mc|
          ring = mc.send(:ring)
          assert_equal ring.servers.first.port, ring.server_for_key('test').port
        end
      end
    end

    it 'detect when a dead server is up again' do
      memcached(19997) do
        down_retry_delay = 0.5
        dc = Dalli::Client.new(['localhost:19997', 'localhost:19998'], :down_retry_delay => down_retry_delay)
        assert_equal 1, dc.stats.values.compact.count

        memcached(19998) do
          assert_equal 2, dc.stats.values.compact.count
        end
      end
    end
  end

  describe 'Ring::Entry' do
    it 'stores value and server' do
      server = stub(:name => 'localhost:11211')
      entry = Dalli::Ring::Entry.new(12345, server)
      assert_equal 12345, entry.value
      assert_equal server, entry.server
    end
  end

  describe 'continuum with weighted servers' do
    it 'gives more entries to higher-weight servers' do
      light = stub(:name => 'light:11211', :weight => 1)
      heavy = stub(:name => 'heavy:11211', :weight => 3)
      ring = Dalli::Ring.new([light, heavy], {})

      light_count = ring.continuum.count { |e| e.server == light }
      heavy_count = ring.continuum.count { |e| e.server == heavy }
      assert_operator heavy_count, :>, light_count
    end

    it 'produces proportional entry counts' do
      s1 = stub(:name => 'a:11211', :weight => 1)
      s2 = stub(:name => 'b:11211', :weight => 2)
      ring = Dalli::Ring.new([s1, s2], {})

      s1_count = ring.continuum.count { |e| e.server == s1 }
      s2_count = ring.continuum.count { |e| e.server == s2 }
      ratio = s2_count.to_f / s1_count
      assert_in_delta 2.0, ratio, 0.1
    end
  end

  describe 'failover disabled' do
    it 'raises RingError immediately when failover is false and server is down' do
      servers = [
        Dalli::Server.new("localhost:12345"),
        Dalli::Server.new("localhost:12346"),
      ]
      ring = Dalli::Ring.new(servers, { failover: false })
      assert_raises Dalli::RingError do
        ring.server_for_key('test')
      end
    end
  end

  describe 'lock' do
    it 'locks and unlocks all servers around a block' do
      s1 = stub(:name => 'a:11211', :weight => 1)
      s2 = stub(:name => 'b:11211', :weight => 1)
      s1.expects(:lock!)
      s1.expects(:unlock!)
      s2.expects(:lock!)
      s2.expects(:unlock!)
      ring = Dalli::Ring.new([s1, s2], { threadsafe: false })

      result = ring.lock { 42 }
      assert_equal 42, result
    end

    it 'unlocks servers even when block raises' do
      s1 = stub(:name => 'a:11211', :weight => 1)
      s1.expects(:lock!)
      s1.expects(:unlock!)
      ring = Dalli::Ring.new([s1], { threadsafe: false })

      assert_raises RuntimeError do
        ring.lock { raise RuntimeError, 'boom' }
      end
    end
  end

  describe 'single server without continuum' do
    it 'does not create a continuum' do
      server = stub(:name => 'localhost:11211', :weight => 1)
      ring = Dalli::Ring.new([server], { threadsafe: false })
      assert_nil ring.continuum
    end
  end
end
