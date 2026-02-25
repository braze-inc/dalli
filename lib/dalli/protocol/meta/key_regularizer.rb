# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      # The meta protocol requires ASCII keys without whitespace. Keys containing
      # non-ASCII characters or whitespace are base64-encoded and sent with the
      # 'b' flag so the server knows to decode them.
      class KeyRegularizer
        WHITESPACE = /\s/

        def self.encode(key)
          return [key, false] if key.ascii_only? && !WHITESPACE.match(key)

          [([key].pack('m0')), true]
        end

        def self.decode(encoded_key, base64_encoded)
          return encoded_key unless base64_encoded

          encoded_key.unpack1('m0').force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end
