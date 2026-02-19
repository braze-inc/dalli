# frozen_string_literal: true
require_relative 'helper'

describe Dalli::Threadsafe do
  let(:server) { Dalli::Server.new('localhost:11211') }

  describe 'when extended onto a server' do
    before do
      server.extend(Dalli::Threadsafe)
    end

    it 'initializes a Monitor lock' do
      lock = server.instance_variable_get(:@lock)
      assert_instance_of Monitor, lock
    end

    it 'responds to lock! and unlock!' do
      assert_respond_to server, :lock!
      assert_respond_to server, :unlock!
    end

    it 'lock! acquires the monitor' do
      server.lock!
      lock = server.instance_variable_get(:@lock)
      assert lock.mon_owned?
      server.unlock!
    end

    it 'unlock! releases the monitor' do
      server.lock!
      server.unlock!
      lock = server.instance_variable_get(:@lock)
      refute lock.mon_owned?
    end

    it 'wraps alive? in synchronize' do
      lock = server.instance_variable_get(:@lock)
      lock.expects(:synchronize).yields
      server.stubs(:connect)
      server.alive?
    end

    it 'wraps close in synchronize' do
      lock = server.instance_variable_get(:@lock)
      lock.expects(:synchronize).yields
      server.close
    end
  end

  describe 'without Threadsafe extension' do
    it 'lock! and unlock! are no-ops' do
      server.lock!
      server.unlock!
    end
  end
end
