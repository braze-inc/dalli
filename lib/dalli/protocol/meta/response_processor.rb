# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      class ResponseProcessor
        TERMINATOR = "\r\n"

        EN = 'EN'
        END_TOKEN = 'END'
        EX = 'EX'
        HD = 'HD'
        MN = 'MN'
        NF = 'NF'
        NS = 'NS'
        OK = 'OK'
        RESET = 'RESET'
        STAT = 'STAT'
        VA = 'VA'
        VERSION = 'VERSION'
        SERVER_ERROR = 'SERVER_ERROR'

        def initialize(server)
          @server = server
        end

        def meta_get_with_value(cache_nils: false)
          tokens = error_on_unexpected!([VA, EN, HD])
          return cache_nils ? Dalli::Protocol::Base::NOT_FOUND : nil if tokens.first == EN
          return true unless tokens.first == VA

          bitflags = bitflags_from_tokens(tokens)
          @server.deserialize(read_data(tokens[1].to_i), bitflags || 0)
        end

        def meta_get_with_value_and_cas
          tokens = error_on_unexpected!([VA, EN, HD])
          return [nil, 0] if tokens.first == EN

          cas = cas_from_tokens(tokens)
          return [nil, cas] unless tokens.first == VA

          bitflags = bitflags_from_tokens(tokens)
          [@server.deserialize(read_data(tokens[1].to_i), bitflags || 0), cas]
        end

        def meta_get_without_value
          tokens = error_on_unexpected!([EN, HD])
          tokens.first == EN ? nil : true
        end

        def meta_set_with_cas
          tokens = error_on_unexpected!([HD, NS, NF, EX])
          return false unless tokens.first == HD

          cas_from_tokens(tokens)
        end

        def meta_set_append_prepend
          tokens = error_on_unexpected!([HD, NS, NF, EX])
          return false unless tokens.first == HD

          true
        end

        def meta_delete
          tokens = error_on_unexpected!([HD, NF, EX])
          tokens.first == HD
        end

        def decr_incr
          tokens = error_on_unexpected!([VA, NF, NS, EX])
          return false if [NS, EX].include?(tokens.first)
          return nil if tokens.first == NF

          read_line.to_i
        end

        def stats
          tokens = error_on_unexpected!([END_TOKEN, STAT])
          values = {}
          while tokens.first != END_TOKEN
            values[tokens[1]] = tokens[2]
            tokens = next_line_to_tokens
          end
          values
        end

        def flush
          error_on_unexpected!([OK])
          true
        end

        def reset
          error_on_unexpected!([RESET])
          true
        end

        def version
          tokens = error_on_unexpected!([VERSION])
          tokens.last
        end

        def consume_all_responses_until_mn
          tokens = next_line_to_tokens
          tokens = next_line_to_tokens while tokens.first != MN
          true
        end

        # Parse a single getk-style response from the multi-get buffer.
        # Returns [status, cas, key, value] or nil components when incomplete.
        def getk_response_from_buffer(buf)
          return [0, nil, nil, nil, nil] unless buf.include?(TERMINATOR)

          header = buf.split(TERMINATOR, 2).first
          tokens = header.split
          header_len = header.bytesize + TERMINATOR.length

          if tokens.first == MN
            return [header_len, true, nil, nil, nil]
          end

          unless tokens.first == VA
            return [header_len, false, nil, nil, nil]
          end

          body_len = tokens[1].to_i
          resp_size = header_len + body_len + TERMINATOR.length

          return [0, nil, nil, nil, nil] unless buf.bytesize >= resp_size

          body = buf.slice(header_len, body_len)
          key = key_from_tokens(tokens)
          cas = cas_from_tokens(tokens)
          bitflags = bitflags_from_tokens(tokens) || 0
          value = @server.deserialize(body, bitflags)

          [resp_size, false, cas, key, value]
        end

        private

        def error_on_unexpected!(expected_codes)
          tokens = next_line_to_tokens
          return tokens if expected_codes.include?(tokens.first)

          raise Dalli::DalliError, "Response error: #{tokens.join(' ')}" if tokens.first == SERVER_ERROR
          raise Dalli::DalliError, "Response error: #{tokens.first}"
        end

        def bitflags_from_tokens(tokens)
          value_from_tokens(tokens, 'f')&.to_i
        end

        def cas_from_tokens(tokens)
          value_from_tokens(tokens, 'c')&.to_i
        end

        def key_from_tokens(tokens)
          encoded_key = value_from_tokens(tokens, 'k')
          return nil unless encoded_key

          base64_encoded = tokens.any?('b')
          KeyRegularizer.decode(encoded_key, base64_encoded)
        end

        def value_from_tokens(tokens, flag)
          token = tokens.find { |t| t.start_with?(flag) && t.length > 1 }
          return nil unless token

          token[1..]
        end

        def read_line
          @server.sock.read_line&.chomp!(TERMINATOR)
        end

        def next_line_to_tokens
          line = read_line
          line&.split || []
        end

        def read_data(data_size)
          @server.sock.read_from_buffer(data_size + TERMINATOR.bytesize)&.chomp!(TERMINATOR)
        end
      end
    end
  end
end
