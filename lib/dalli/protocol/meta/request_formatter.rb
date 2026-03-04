# frozen_string_literal: true

module Dalli
  module Protocol
    class Meta
      # Builds wire-format command strings for memcached text/meta protocols.
      #
      # This class is intentionally "stringly typed": each formatter emits the
      # exact command bytes expected by memcached over the text protocol socket.
      # Think of each method as a tiny serializer from Ruby keyword arguments to
      # memcached command tokens.
      #
      # ## Meta command syntax origins
      #
      # - `mg`, `ms`, `md`, `ma`, `mn` and their option tokens (`v`, `f`, `c`,
      #   `b`, `k`, `q`, `s`, `F`, `C`, `T`, `M`, `D`, `J`, `N`) come from the
      #   memcached meta protocol documentation:
      #   https://github.com/memcached/memcached/wiki/MetaCommands
      # - `version`, `stats`, and `flush_all` come from the classic memcached
      #   text protocol:
      #   https://github.com/memcached/memcached/blob/master/doc/protocol.txt
      #
      # ## Reading the command builders
      #
      # - Uppercase-leading options (for example `T90`, `C123`, `MZ`) carry a
      #   value directly after the option letter.
      # - Standalone lowercase options (for example `v`, `f`, `q`) are boolean
      #   toggles that are present only when enabled.
      # - Every command is terminated with CRLF (`"\r\n"`), per text protocol.
      class RequestFormatter
        APPEND_PREPEND_MODES = %i[append prepend].freeze
        MODE_TOKENS = { add: 'E', replace: 'R', append: 'A', prepend: 'P', set: 'S' }.freeze
        TERMINATOR = "\r\n"

        def self.meta_get(key:, value: true, return_cas: false, ttl: nil, base64: false, quiet: false)
          if quiet && value && return_cas && !ttl
            base64 ? "mg #{key} v f c b k q s\r\n" : "mg #{key} v f c k q s\r\n"
          elsif !quiet && value && !return_cas && !ttl
            base64 ? "mg #{key} v f b\r\n" : "mg #{key} v f\r\n"
          else
            cmd = "mg #{key}"
            cmd << ' v f' if value
            cmd << ' c' if return_cas
            cmd << ' b' if base64
            cmd << " T#{ttl}" if ttl
            cmd << ' k q s' if quiet
            cmd << TERMINATOR
          end
        end

        def self.meta_set(key:, value:, bitflags: nil, cas: nil, ttl: nil, mode: :set, base64: false, quiet: false)
          cmd = "ms #{key} #{value.bytesize}"
          cmd << ' c' unless APPEND_PREPEND_MODES.include?(mode)
          cmd << ' b' if base64
          cmd << " F#{bitflags}" if bitflags && bitflags != 0
          cmd << " C#{cas}" if cas && cas != 0
          cmd << " T#{ttl}" if ttl
          cmd << " M#{MODE_TOKENS[mode] || 'S'}"
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
          cmd << " #{delay.to_i}" if delay
          cmd << TERMINATOR
        end

        def self.stats(arg = nil)
          cmd = +'stats'
          cmd << " #{arg}" if arg && !arg.empty?
          cmd << TERMINATOR
        end

        def self.cas_string(cas)
          cas && cas != 0 ? " C#{cas}" : ''
        end
      end
    end
  end
end
