# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      # The meta protocol requires ASCII keys without whitespace. Keys containing
      # non-ASCII characters or whitespace are base64-encoded and sent with the
      # 'b' flag so the server knows to decode them.
      class KeyRegularizer
        # Memcached text/meta keys cannot contain control chars or spaces.
        INVALID_META_KEY_CHARS = /[\x00-\x20\x7F]/

        def self.encode(key)
          return [key, false] if key.ascii_only? && !INVALID_META_KEY_CHARS.match?(key)

          [([key].pack('m0')), true]
        end

        def self.decode(encoded_key, base64_encoded)
          return encoded_key unless base64_encoded

          decoded = encoded_key.unpack1('m0')
          utf8 = decoded.dup.force_encoding(Encoding::UTF_8)
          utf8.valid_encoding? ? utf8 : decoded.force_encoding(Encoding::BINARY)
        end
      end
    end
  end
end
