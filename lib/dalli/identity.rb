# frozen_string_literal: true

module Dalli
  class Identity
    # A no-op serializer/compressor that always returns its input

    class << self
      def dump(value)
        return value
      end

      def load(value)
        return value
      end

      def compress(value)
        return value
      end

      def decompress(value)
        return value
      end
    end
  end
end
