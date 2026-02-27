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
          line = read_line
          return cache_nils ? Dalli::Protocol::Base::NOT_FOUND : nil if line.start_with?(EN)
          return true if line.start_with?(HD)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(VA)

          sp1 = 3
          sp2 = line.index(' ', sp1) || line.length
          data_size = line.byteslice(sp1, sp2 - sp1).to_i
          bitflags = extract_flag_value(line, 'f', sp2) || 0
          @server.deserialize(read_data(data_size), bitflags)
        end

        def meta_get_with_value_and_cas
          line = read_line
          return [nil, 0] if line.start_with?(EN)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(VA) || line.start_with?(HD)

          cas = extract_flag_value(line, 'c', 2) || 0
          return [nil, cas] unless line.start_with?(VA)

          sp1 = 3
          sp2 = line.index(' ', sp1) || line.length
          data_size = line.byteslice(sp1, sp2 - sp1).to_i
          bitflags = extract_flag_value(line, 'f', sp2) || 0
          [@server.deserialize(read_data(data_size), bitflags), cas]
        end

        def meta_get_without_value
          line = read_line
          return nil if line.start_with?(EN)
          return true if line.start_with?(HD)
          raise Dalli::DalliError, "Response error: #{line}"
        end

        def meta_set_with_cas
          line = read_line
          return false if line.start_with?(NS) || line.start_with?(NF) || line.start_with?(EX)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(HD)

          extract_flag_value(line, 'c', 2) || 0
        end

        def meta_set_append_prepend
          line = read_line
          return false if line.start_with?(NS) || line.start_with?(NF) || line.start_with?(EX)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(HD)

          true
        end

        def meta_delete
          line = read_line
          return false if line.start_with?(NF) || line.start_with?(EX)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(HD)

          true
        end

        def decr_incr
          line = read_line
          return false if line.start_with?(NS) || line.start_with?(EX)
          return nil if line.start_with?(NF)
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(VA)

          read_line.to_i
        end

        def stats
          line = read_line
          values = {}
          while !line.start_with?(END_TOKEN)
            raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(STAT)
            parts = line.split(nil, 3)
            values[parts[1]] = parts[2]
            line = read_line
          end
          values
        end

        def flush
          line = read_line
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(OK)
          true
        end

        def reset
          line = read_line
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(RESET)
          true
        end

        def version
          line = read_line
          raise Dalli::DalliError, "Response error: #{line}" unless line.start_with?(VERSION)
          line.split(nil, 2).last
        end

        def consume_all_responses_until_mn
          line = read_line
          line = read_line while !line.start_with?(MN)
          true
        end

        # Parse a single getk-style response from the buffer starting at pos.
        # Returns [advance, is_terminal, cas, key, value] where advance is
        # bytes consumed (0 if incomplete).
        def getk_response_from_buffer(buf, pos = 0)
          term_idx = buf.index(TERMINATOR, pos)
          return [0, nil, nil, nil, nil] unless term_idx

          first_byte = buf.getbyte(pos)

          if first_byte == 77 # 'M' (MN - pipeline complete)
            return [term_idx + 2 - pos, true, nil, nil, nil]
          end

          unless first_byte == 86 # 'V' (VA - value response)
            return [term_idx + 2 - pos, false, nil, nil, nil]
          end

          sp1 = pos + 3
          sp2 = buf.index(' ', sp1) || term_idx
          body_len = buf.byteslice(sp1, sp2 - sp1).to_i

          header_len = term_idx + 2 - pos
          resp_size = header_len + body_len + 2
          return [0, nil, nil, nil, nil] unless buf.bytesize >= pos + resp_size

          body = buf.byteslice(term_idx + 2, body_len)

          key = nil
          cas = 0
          bitflags = 0
          base64 = false
          scan = sp2
          while scan < term_idx
            scan += 1
            flag_byte = buf.getbyte(scan)
            next_sp = buf.index(' ', scan + 1) || term_idx
            case flag_byte
            when 107 then key = buf.byteslice(scan + 1, next_sp - scan - 1) # 'k'
            when 99  then cas = buf.byteslice(scan + 1, next_sp - scan - 1).to_i # 'c'
            when 102 then bitflags = buf.byteslice(scan + 1, next_sp - scan - 1).to_i # 'f'
            when 98  then base64 = true # 'b'
            end
            scan = next_sp
          end

          key = KeyRegularizer.decode(key, true) if key && base64
          value = @server.deserialize(body, bitflags)

          [resp_size, false, cas, key, value]
        end

        private

        # Extract a flag value from a response line by scanning for " <flag><value>"
        # without splitting the entire line into tokens.
        def extract_flag_value(line, flag_char, start_pos)
          search = " #{flag_char}"
          idx = line.index(search, start_pos)
          return nil unless idx

          val_start = idx + 2
          val_end = line.index(' ', val_start) || line.length
          return nil if val_start == val_end

          line.byteslice(val_start, val_end - val_start).to_i
        end

        def read_line
          @server.sock.read_line&.chomp!(TERMINATOR)
        end

        def read_data(data_size)
          @server.sock.read_from_buffer(data_size + TERMINATOR.bytesize)&.chomp!(TERMINATOR)
        end
      end
    end
  end
end
