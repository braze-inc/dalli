# frozen_string_literal: true
require_relative 'helper'

describe 'Identity' do
  subject { Dalli::Identity }

  let(:some_value) { SecureRandom.alphanumeric(10) }
  
  it "implements the serializer interface (dump/load) with the identity function" do
    assert_equal(some_value, subject.dump(some_value))
    assert_equal(some_value, subject.load(some_value))
  end

  it "implements the compressor interface (compress/decompress) with the identity function" do
    assert_equal(some_value, subject.compress(some_value))
    assert_equal(some_value, subject.decompress(some_value))
  end

  it "works as a compressor & serializer" do
    memcached(29199) do |_, port|
      dc = Dalli::Client.new("localhost:#{port}", :compressor => subject, :serializer => subject)
      dc.set('some_key', 'some_value')
      assert_equal('some_value', dc.get('some_key')) 
    end
  end
end
