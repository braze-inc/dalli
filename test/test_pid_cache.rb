# frozen_string_literal: true
require_relative 'helper'

describe Dalli::PIDCache do
  it 'returns the current process PID' do
    assert_equal Process.pid, Dalli::PIDCache.pid
  end

  it 'responds to .pid' do
    assert_respond_to Dalli::PIDCache, :pid
  end

  if Process.respond_to?(:_fork)
    describe 'on Ruby 3.1+ with Process._fork' do
      it 'responds to update!' do
        assert_respond_to Dalli::PIDCache, :update!
      end

      it 'updates pid to match Process.pid' do
        Dalli::PIDCache.update!
        assert_equal Process.pid, Dalli::PIDCache.pid
      end

      it 'has CoreExt prepended on Process' do
        assert Process.singleton_class.ancestors.include?(Dalli::PIDCache::CoreExt)
      end

      if Process.respond_to?(:fork)
        it 'resets pid cache in child after fork' do
          parent_pid = Process.pid

          rd, wr = IO.pipe
          child_pid = Process.fork do
            rd.close
            wr.write Dalli::PIDCache.pid.to_s
            wr.close
          end
          wr.close
          cached_pid_in_child = rd.read.to_i
          rd.close
          Process.wait(child_pid)

          assert_equal child_pid, cached_pid_in_child
          refute_equal parent_pid, cached_pid_in_child
        end
      end
    end
  elsif !Process.respond_to?(:fork)
    describe 'on JRuby/TruffleRuby without fork' do
      it 'returns a fixed pid' do
        assert_equal Process.pid, Dalli::PIDCache.pid
      end
    end
  else
    describe 'on Ruby 3.0 or older' do
      it 'delegates directly to Process.pid' do
        assert_equal Process.pid, Dalli::PIDCache.pid
      end
    end
  end
end
