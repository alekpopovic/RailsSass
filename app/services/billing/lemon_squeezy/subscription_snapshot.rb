require "time"

module Billing
  module LemonSqueezy
    class SubscriptionSnapshot
      class ParseError < Errors::InvalidResponseError; end

      KNOWN_STATUSES = %w[
        on_trial active paused past_due unpaid cancelled expired
      ].freeze
      PROVIDER_ID_PATTERN = /\A[a-zA-Z0-9_-]{1,128}\z/
      NUMERIC_ID_PATTERN = /\A[1-9][0-9]{0,127}\z/
      STATUS_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
      EVENT_NAME_PATTERN = /\A[a-z][a-z0-9_]{0,99}\z/
      TIMESTAMP_PATTERN =
        /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/
      PAUSE_KEYS = %w[mode resumes_at].freeze
      PAUSE_MODES = %w[free void].freeze
      CARD_BRAND_PATTERN = /\A[^[:cntrl:]]{1,32}\z/
      CRITICAL_KEYS = %w[
        card_brand card_last_four ends_at pause provider_created_at provider_customer_id
        provider_product_id provider_store_id provider_subscription_id
        provider_updated_at provider_variant_id renews_at status test_mode
        trial_ends_at
      ].freeze

      attr_reader :provider_subscription_id,
        :provider_store_id,
        :provider_customer_id,
        :provider_product_id,
        :provider_variant_id,
        :provider_status,
        :status,
        :test_mode,
        :created_at,
        :provider_updated_at,
        :trial_ends_at,
        :renews_at,
        :ends_at,
        :pause,
        :card_brand,
        :card_last_four

      class << self
        def parse(**attributes)
          Parser.new(**attributes).call
        end
      end

      def initialize(**attributes)
        attributes.each { |name, value| instance_variable_set(:"@#{name}", value) }
        @pause = pause.freeze
        freeze
      end

      def known_status?
        status != "unknown"
      end

      def to_h
        {
          "provider_subscription_id" => provider_subscription_id,
          "provider_store_id" => provider_store_id,
          "provider_customer_id" => provider_customer_id,
          "provider_product_id" => provider_product_id,
          "provider_variant_id" => provider_variant_id,
          "status" => status,
          "test_mode" => test_mode,
          "provider_created_at" => serialized_time(created_at),
          "provider_updated_at" => serialized_time(provider_updated_at),
          "trial_ends_at" => serialized_time(trial_ends_at),
          "renews_at" => serialized_time(renews_at),
          "ends_at" => serialized_time(ends_at),
          "pause" => pause,
          "card_brand" => card_brand,
          "card_last_four" => card_last_four
        }.compact
      end

      def sanitized_payload(event_name: nil)
        return to_h if event_name.nil?

        normalized_event_name = event_name.to_s
        unless EVENT_NAME_PATTERN.match?(normalized_event_name)
          raise ParseError.new("Invalid Lemon Squeezy event name", status: 200), cause: nil
        end

        to_h.merge("event_name" => normalized_event_name)
      end

      def critical_attributes
        to_h.slice(*CRITICAL_KEYS)
      end

      private
        def serialized_time(value)
          value&.iso8601(6)
        end

        class Parser
          def initialize(payload:, expected_subscription_id:, expected_store_id:, expected_test_mode:)
            @payload = payload
            @expected_subscription_id = expected_subscription_id.to_s
            @expected_store_id = expected_store_id.to_s
            @expected_test_mode = expected_test_mode
          end

          def call
            validate_expected_identity!
            data = required_hash(@payload)
            invalid! unless data.keys.include?("data")
            data = required_hash(data["data"])
            invalid! unless data["type"] == "subscriptions"

            provider_subscription_id = provider_id(data["id"])
            invalid! unless provider_subscription_id == @expected_subscription_id
            attributes = required_hash(data["attributes"])
            parsed = parse_attributes(attributes, provider_subscription_id:)
            validate_timestamps!(parsed)

            SubscriptionSnapshot.new(**parsed)
          rescue ParseError
            raise
          rescue ArgumentError, TypeError
            invalid!
          end

          private
            def parse_attributes(attributes, provider_subscription_id:)
              provider_status = status_value(attributes["status"])
              {
                provider_subscription_id:,
                provider_store_id: numeric_id(attributes["store_id"]),
                provider_customer_id: numeric_id(attributes["customer_id"]),
                provider_product_id: numeric_id(attributes["product_id"]),
                provider_variant_id: numeric_id(attributes["variant_id"]),
                provider_status:,
                status: normalized_status(provider_status),
                test_mode: test_mode(attributes["test_mode"]),
                created_at: required_time(attributes["created_at"]),
                provider_updated_at: required_time(attributes["updated_at"]),
                trial_ends_at: optional_time(attributes["trial_ends_at"]),
                renews_at: optional_time(attributes["renews_at"]),
                ends_at: optional_time(attributes["ends_at"]),
                pause: pause_value(attributes["pause"]),
                card_brand: card_brand(attributes["card_brand"]),
                card_last_four: card_last_four(attributes["card_last_four"])
              }.tap do |values|
                validate_store_and_environment!(values)
                validate_card!(values)
              end
            end

            def validate_expected_identity!
              invalid! unless PROVIDER_ID_PATTERN.match?(@expected_subscription_id)
              invalid! unless NUMERIC_ID_PATTERN.match?(@expected_store_id)
              invalid! unless @expected_test_mode == true || @expected_test_mode == false
            end

            def validate_store_and_environment!(values)
              invalid! unless values.fetch(:provider_store_id) == @expected_store_id
              invalid! unless values.fetch(:test_mode) == @expected_test_mode
            end

            def validate_card!(values)
              brand = values.fetch(:card_brand)
              last_four = values.fetch(:card_last_four)
              invalid! unless brand.nil? == last_four.nil?
            end

            def validate_timestamps!(values)
              created_at = values.fetch(:created_at)
              updated_at = values.fetch(:provider_updated_at)
              invalid! if updated_at < created_at

              %i[trial_ends_at renews_at ends_at].each do |name|
                value = values.fetch(name)
                invalid! if value && value < created_at
              end

              provider_status = values.fetch(:provider_status)
              invalid! if provider_status == "on_trial" && values[:trial_ends_at].nil?
              if provider_status.in?(%w[cancelled expired])
                invalid! if values[:ends_at].nil?
              elsif values.fetch(:status) != "unknown" && values[:ends_at]
                invalid!
              end
            end

            def required_hash(value)
              invalid! unless value.is_a?(Hash)

              value
            end

            def provider_id(value)
              invalid! unless value.is_a?(String) && PROVIDER_ID_PATTERN.match?(value)

              value
            end

            def numeric_id(value)
              normalized = value.is_a?(Integer) ? value.to_s : value
              invalid! unless normalized.is_a?(String) && NUMERIC_ID_PATTERN.match?(normalized)

              normalized
            end

            def status_value(value)
              invalid! unless value.is_a?(String) && STATUS_PATTERN.match?(value)

              value
            end

            def normalized_status(value)
              KNOWN_STATUSES.include?(value) ? value : "unknown"
            end

            def test_mode(value)
              invalid! unless value == true || value == false

              value
            end

            def required_time(value)
              optional_time(value) || invalid!
            end

            def optional_time(value)
              return if value.nil?
              invalid! unless value.is_a?(String) && TIMESTAMP_PATTERN.match?(value)

              Time.iso8601(value).utc
            rescue ArgumentError
              invalid!
            end

            def pause_value(value)
              return {} if value.nil?
              invalid! unless value.is_a?(Hash) && (value.keys - PAUSE_KEYS).empty?

              mode = value["mode"]
              invalid! unless PAUSE_MODES.include?(mode)
              resumes_at = optional_time(value["resumes_at"])
              { "mode" => mode, "resumes_at" => resumes_at&.iso8601(6) }.compact
            end

            def card_brand(value)
              return if value.nil?
              invalid! unless value.is_a?(String)

              normalized = value.strip
              return if normalized.empty?

              invalid! unless value == normalized && CARD_BRAND_PATTERN.match?(normalized)
              normalized
            end

            def card_last_four(value)
              return if value.nil?
              return if value == ""

              invalid! unless value.is_a?(String) && /\A[0-9]{4}\z/.match?(value)

              value
            end

            def invalid!
              raise ParseError.new(
                "Lemon Squeezy returned an invalid subscription snapshot",
                status: 200
              ), cause: nil
            end
        end
    end
  end
end
