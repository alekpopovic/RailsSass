require "json"

module Billing
  module SanitizedPayload
    MAX_BYTES = 65_536
    MAX_DEPTH = 20
    SENSITIVE_KEYS = %w[
      api_key apikey authorization card_number checkout_url custom_data cvc cvv
      email email_address name password portal_url secret signature url
      x_api_key x_signature
    ].freeze
    SENSITIVE_KEY_PATTERNS = [
      /(?:\A|_)(?:email|password|token|secret)(?:\z|_)/,
      /\A(?:customer|user)_name\z/,
      /(?:\A|_)card_number\z/,
      /_url\z/
    ].freeze
    SAFE_DERIVED_KEYS = %w[checkout_token_digest].freeze

    class << self
      def validate(record, attribute, allowed_keys:)
        value = record.public_send(attribute)
        unless value.is_a?(Hash)
          record.errors.add(attribute, "must be an object")
          return
        end

        if serialized_size(value) > MAX_BYTES
          record.errors.add(attribute, "must be at most 64 KiB")
        end

        keys = nested_keys(value)
        if keys.any? { |key| sensitive_key?(key) }
          record.errors.add(attribute, "contains a sensitive field")
        elsif (keys - allowed_keys).any?
          record.errors.add(attribute, "contains an unsupported field")
        end
      rescue JSON::GeneratorError, JSON::NestingError, SystemStackError
        record.errors.add(attribute, "must be a bounded JSON object")
      end

      private
        def serialized_size(value)
          JSON.generate(value, max_nesting: MAX_DEPTH).bytesize
        end

        def nested_keys(value, depth = 0)
          raise JSON::NestingError, "payload nesting is too deep" if depth > MAX_DEPTH

          case value
          when Hash
            value.each_with_object([]) do |(key, nested_value), keys|
              keys << normalize_key(key)
              keys.concat(nested_keys(nested_value, depth + 1))
            end
          when Array
            value.flat_map { |nested_value| nested_keys(nested_value, depth + 1) }
          else
            []
          end
        end

        def normalize_key(key)
          key.to_s
            .strip
            .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
            .tr("-", "_")
            .downcase
        end

        def sensitive_key?(key)
          return false if SAFE_DERIVED_KEYS.include?(key)

          SENSITIVE_KEYS.include?(key) ||
            SENSITIVE_KEY_PATTERNS.any? { |pattern| pattern.match?(key) }
        end
    end
  end
end
