# frozen_string_literal: false

module Dalli
  module Protocol
    class Meta
      class RequestFormatter
        TERMINATOR = "\r\n"

        def self.meta_get(key:, value: true, return_cas: false, ttl: nil, base64: false, quiet: false)
          cmd = "mg #{key}"
          cmd << ' v f' if value
          cmd << ' c' if return_cas
          cmd << ' b' if base64
          cmd << " T#{ttl}" if ttl
          cmd << ' k q s' if quiet
          cmd << TERMINATOR
        end

        def self.meta_set(key:, value:, bitflags: nil, cas: nil, ttl: nil, mode: :set, base64: false, quiet: false)
          cmd = "ms #{key} #{value.bytesize}"
          cmd << ' c' unless %i[append prepend].include?(mode)
          cmd << ' b' if base64
          cmd << " F#{bitflags}" if bitflags
          cmd << cas_string(cas)
          cmd << " T#{ttl}" if ttl
          cmd << " M#{mode_to_token(mode)}"
          cmd << ' q' if quiet
          cmd << TERMINATOR
        end

        def self.meta_delete(key:, cas: nil, base64: false, quiet: false)
          cmd = "md #{key}"
          cmd << ' b' if base64
          cmd << cas_string(cas)
          cmd << ' q' if quiet
          cmd << TERMINATOR
        end

        def self.meta_arithmetic(key:, delta:, initial:, incr: true, cas: nil, ttl: nil, base64: false, quiet: false)
          cmd = "ma #{key} v"
          cmd << ' b' if base64
          cmd << " D#{delta}" if delta
          cmd << " J#{initial}" if initial
          cmd << " N#{ttl || 0}" if ttl || initial
          cmd << cas_string(cas)
          cmd << ' q' if quiet
          cmd << " M#{incr ? 'I' : 'D'}"
          cmd << TERMINATOR
        end

        def self.meta_noop
          "mn\r\n"
        end

        def self.version
          "version\r\n"
        end

        def self.flush(delay: nil)
          cmd = +'flush_all'
          cmd << " #{parse_to_64_bit_int(delay, 0)}" if delay
          cmd << TERMINATOR
        end

        def self.stats(arg = nil)
          cmd = +'stats'
          cmd << " #{arg}" if arg && !arg.empty?
          cmd << TERMINATOR
        end

        def self.mode_to_token(mode)
          case mode
          when :add then 'E'
          when :replace then 'R'
          when :append then 'A'
          when :prepend then 'P'
          else 'S'
          end
        end

        def self.cas_string(cas)
          cas = parse_to_64_bit_int(cas, nil)
          cas.nil? || cas.zero? ? '' : " C#{cas}"
        end

        def self.parse_to_64_bit_int(val, default)
          val.nil? ? nil : Integer(val)
        rescue ArgumentError
          default
        end
      end
    end
  end
end
