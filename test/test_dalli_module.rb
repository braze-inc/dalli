# frozen_string_literal: true
require_relative 'helper'

describe 'Dalli module' do
  describe 'version' do
    it 'is defined' do
      refute_nil Dalli::VERSION
    end

    it 'is a string' do
      assert_kind_of String, Dalli::VERSION
    end
  end

  describe 'error classes' do
    it 'defines DalliError as a RuntimeError' do
      assert Dalli::DalliError < RuntimeError
    end

    it 'defines NetworkError as a DalliError' do
      assert Dalli::NetworkError < Dalli::DalliError
    end

    it 'defines RingError as a DalliError' do
      assert Dalli::RingError < Dalli::DalliError
    end

    it 'defines MarshalError as a DalliError' do
      assert Dalli::MarshalError < Dalli::DalliError
    end

    it 'defines UnmarshalError as a DalliError' do
      assert Dalli::UnmarshalError < Dalli::DalliError
    end

    it 'defines ValueOverMaxSize as a DalliError' do
      assert Dalli::ValueOverMaxSize < Dalli::DalliError
    end
  end

  describe 'logger' do
    after do
      Dalli.logger = Logger.new(STDOUT)
      Dalli.logger.level = Logger::ERROR
    end

    it 'has a default logger' do
      Dalli.instance_variable_set(:@logger, nil)
      refute_nil Dalli.logger
    end

    it 'allows setting a custom logger' do
      custom = Logger.new(nil)
      Dalli.logger = custom
      assert_equal custom, Dalli.logger
    end

    it 'default_logger creates an INFO-level STDOUT logger' do
      logger = Dalli.default_logger
      assert_equal Logger::INFO, logger.level
    end
  end
end
