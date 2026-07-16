require "digest"
require "json"

module Billing
  module Webhooks
    class Receive
      PROVIDER = "lemon_squeezy"
      MAX_BODY_BYTES = 256.kilobytes
      MAX_TOKEN_BYTES = 2_048
      MAX_NESTING = 50
      SAFE_EVENT_NAME = /\A[a-z][a-z0-9_]*\z/
      SAFE_RESOURCE_TYPE = /\A[a-z][a-z0-9_-]*\z/
      SAFE_PROVIDER_ID = /\A\S+\z/
      SAFE_STORE_ID = /\A[1-9][0-9]*\z/
      SAFE_STATUS = /\A[a-z][a-z0-9_]*\z/
      SUBSCRIPTION_EVENTS = %w[
        subscription_created
        subscription_expired
        subscription_updated
      ].freeze
      PAYMENT_EVENTS = %w[
        subscription_payment_failed
        subscription_payment_recovered
        subscription_payment_success
      ].freeze
      PROCESSABLE_EVENTS = (SUBSCRIPTION_EVENTS + PAYMENT_EVENTS).freeze

      Result = Data.define(:status, :event, :duplicate, :enqueue_failed)

      def self.call(**attributes)
        new(**attributes).call
      end

      def initialize(
        body:,
        signature:,
        content_type:,
        secret: Rails.configuration.x.billing.lemon_squeezy.webhook_secret,
        environment: Rails.configuration.x.billing.lemon_squeezy.environment,
        store_id: Rails.configuration.x.billing.lemon_squeezy.store_id,
        request_id: nil,
        now: Time.current
      )
        @body = body
        @signature = signature
        @content_type = content_type.to_s
        @verifier = SignatureVerifier.new(secret: secret)
        @environment = environment.to_s
        @store_id = store_id.to_s
        @request_id = safe_request_id(request_id)
        @now = now
      end

      def call
        raw_body = read_raw_body
        return result(413) if raw_body.bytesize > MAX_BODY_BYTES
        return result(503) unless @verifier.configured?
        return result(401) unless @verifier.valid?(raw_body: raw_body, signature: @signature)
        return result(415) unless json_content_type?

        parsed_payload = parse_payload(raw_body)
        return result(400) unless parsed_payload.is_a?(Hash)
        return result(503) unless provider_configuration_valid?

        event, created = persist_event(raw_body, parsed_payload)
        log_quarantine(event) if created && event.status_quarantined?
        enqueued = Billing::Webhooks::Enqueue.call(event)

        Result.new(
          status: 200,
          event: event,
          duplicate: !created,
          enqueue_failed: !enqueued
        )
      rescue JSON::ParserError, EncodingError
        result(400)
      rescue StandardError
        Rails.logger.error(
          "billing_webhook_receipt_failed reason=internal_error request_id=#{@request_id}"
        )
        result(503)
      end

      private
        def result(status)
          Result.new(status: status, event: nil, duplicate: false, enqueue_failed: false)
        end

        def json_content_type?
          @content_type.split(";", 2).first.to_s.strip.casecmp?("application/json")
        end

        def read_raw_body
          @body.read(MAX_BODY_BYTES + 1).to_s.b
        end

        def provider_configuration_valid?
          @environment.in?(%w[test live]) &&
            SAFE_STORE_ID.match?(@store_id)
        end

        def parse_payload(raw_body)
          JSON.parse(raw_body, max_nesting: MAX_NESTING)
        end

        def persist_event(raw_body, parsed_payload)
          body_sha256 = Digest::SHA256.hexdigest(raw_body)
          fingerprint = Digest::SHA256.hexdigest(
            "#{PROVIDER}\0#{@environment}\0".b + raw_body
          )
          event_name = safe_value(
            nested_value(parsed_payload, "meta", "event_name"),
            maximum: 100,
            pattern: SAFE_EVENT_NAME
          )
          external_resource_type = safe_value(
            nested_value(parsed_payload, "data", "type"),
            maximum: 64,
            pattern: SAFE_RESOURCE_TYPE
          )
          external_resource_id = safe_value(
            nested_value(parsed_payload, "data", "id"),
            maximum: 128,
            pattern: SAFE_PROVIDER_ID
          )
          payload = sanitized_payload(
            parsed_payload,
            event_name: event_name,
            resource_type: external_resource_type,
            resource_id: external_resource_id
          )
          test_mode = trusted_test_mode(payload["test_mode"])
          disposition = disposition_for(
            event_name: event_name,
            resource_type: external_resource_type,
            resource_id: external_resource_id,
            subscription_id: payload["provider_subscription_id"],
            store_id: payload["provider_store_id"],
            test_mode: payload["test_mode"]
          )
          payload["reason_code"] = disposition.fetch(:reason_code) if disposition[:reason_code]

          existing_event = reverified_event(
            fingerprint: fingerprint,
            body_sha256: body_sha256,
            event_name: event_name,
            external_resource_type: external_resource_type,
            external_resource_id: external_resource_id,
            payload: payload,
            test_mode: test_mode,
            disposition: disposition
          )
          return [ existing_event, false ] if existing_event

          event = Billing::WebhookEvent.create!(
            provider: PROVIDER,
            environment: @environment,
            fingerprint: fingerprint,
            event_name: event_name,
            external_resource_type: external_resource_type,
            external_resource_id: external_resource_id,
            body_sha256: body_sha256,
            payload: payload,
            status: disposition.fetch(:status),
            test_mode: test_mode,
            ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION,
            received_at: @now,
            verified_at: @now,
            processed_at: disposition[:processed_at],
            attempts_count: 0,
            error_code: disposition[:error_code]
          )

          [ event, true ]
        rescue ActiveRecord::RecordNotUnique => error
          existing_event = reverified_event(
            fingerprint: fingerprint,
            body_sha256: body_sha256,
            event_name: event_name,
            external_resource_type: external_resource_type,
            external_resource_id: external_resource_id,
            payload: payload,
            test_mode: test_mode,
            disposition: disposition
          )
          raise error unless existing_event

          [ existing_event, false ]
        rescue ActiveRecord::RecordInvalid => error
          existing_event = reverified_event(
            fingerprint: fingerprint,
            body_sha256: body_sha256,
            event_name: event_name,
            external_resource_type: external_resource_type,
            external_resource_id: external_resource_id,
            payload: payload,
            test_mode: test_mode,
            disposition: disposition
          )
          raise error unless existing_event && error.record.errors.of_kind?(:fingerprint, :taken)

          [ existing_event, false ]
        end

        def reverified_event(
          fingerprint:,
          body_sha256:,
          event_name:,
          external_resource_type:,
          external_resource_id:,
          payload:,
          test_mode:,
          disposition:
        )
          event = Billing::WebhookEvent.find_by(
            provider: PROVIDER,
            environment: @environment,
            fingerprint: fingerprint,
            body_sha256: body_sha256
          )
          return unless event
          return event if event.ingress_version == Billing::WebhookEvent::CURRENT_INGRESS_VERSION
          return event unless event.status_received?

          Billing::WebhookEvent
            .where(id: event.id, ingress_version: nil, status: "received")
            .update_all(
              event_name: event_name,
              external_resource_type: external_resource_type,
              external_resource_id: external_resource_id,
              provider_resource_id: external_resource_id,
              payload: payload,
              snapshot: payload,
              status: disposition.fetch(:status),
              test_mode: test_mode,
              enqueued_at: nil,
              processing_started_at: nil,
              processed_at: disposition[:processed_at],
              failed_at: nil,
              error_code: disposition[:error_code],
              error_class: nil,
              error_message: nil,
              ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION,
              updated_at: @now
            )
          event.reload
        end

        def sanitized_payload(parsed_payload, event_name:, resource_type:, resource_id:)
          attributes = nested_value(parsed_payload, "data", "attributes")
          attributes = {} unless attributes.is_a?(Hash)
          checkout_context = verified_checkout_context(parsed_payload)

          {
            "event_name" => event_name,
            "resource_type" => resource_type,
            "provider_resource_id" => resource_id,
            "provider_subscription_id" => subscription_id_for(
              resource_type,
              resource_id,
              attributes
            ),
            "provider_store_id" => provider_id(attributes["store_id"]),
            "provider_product_id" => provider_id(attributes["product_id"]),
            "provider_variant_id" => provider_id(attributes["variant_id"]),
            "provider_customer_id" => provider_id(attributes["customer_id"]),
            "status" => subscription_status(resource_type, attributes["status"]),
            "payment_status" => payment_status(resource_type, attributes["status"]),
            "test_mode" => boolean_value(attributes["test_mode"]),
            "trial_ends_at" => bounded_scalar(attributes["trial_ends_at"]),
            "renews_at" => bounded_scalar(attributes["renews_at"]),
            "ends_at" => bounded_scalar(attributes["ends_at"]),
            "provider_updated_at" => bounded_scalar(attributes["updated_at"]),
            **checkout_context
          }.compact
        end

        def verified_checkout_context(parsed_payload)
          raw_token = checkout_context_token(parsed_payload)
          return {} unless raw_token

          token_payload = Billing::Checkouts::Token.verify(raw_token, now: @now)
          return {} unless token_payload

          {
            "checkout_token_digest" => Billing::Checkouts::Token.digest_nonce(token_payload.nonce),
            "checkout_organization_public_id" => token_payload.organization_public_id,
            "checkout_plan_price_id" => token_payload.plan_price_id,
            "checkout_user_id" => token_payload.user_id,
            "checkout_expires_at" => token_payload.expires_at.iso8601(6)
          }
        end

        def checkout_context_token(parsed_payload)
          custom_data = nested_value(parsed_payload, "meta", "custom_data")
          return unless custom_data.is_a?(Hash)

          candidates = %w[checkout_attempt_token checkout_context]
            .filter_map { |key| custom_data[key] }
          return if candidates.empty?
          return unless candidates.all? { |token| token.is_a?(String) && token.bytesize <= MAX_TOKEN_BYTES }

          candidates.first if candidates.uniq.one?
        end

        def subscription_id_for(resource_type, resource_id, attributes)
          if resource_type == "subscriptions"
            resource_id
          elsif resource_type == "subscription-invoices"
            provider_id(attributes["subscription_id"])
          end
        end

        def subscription_status(resource_type, value)
          safe_status(value) if resource_type == "subscriptions"
        end

        def payment_status(resource_type, value)
          safe_status(value) if resource_type == "subscription-invoices"
        end

        def safe_status(value)
          safe_value(value, maximum: 64, pattern: SAFE_STATUS)
        end

        def disposition_for(event_name:, resource_type:, resource_id:, subscription_id:, store_id:, test_mode:)
          if event_name.nil?
            return terminal_disposition(:quarantined, "invalid_event_envelope")
          end
          unless PROCESSABLE_EVENTS.include?(event_name)
            return terminal_disposition(:ignored, "unsupported_event")
          end
          unless expected_resource_type(event_name) == resource_type && resource_id && subscription_id
            return terminal_disposition(:quarantined, "invalid_subscription_resource")
          end
          unless store_id == @store_id
            return terminal_disposition(:quarantined, "store_mismatch")
          end
          if trusted_test_mode(test_mode).nil?
            return terminal_disposition(:quarantined, "environment_mismatch")
          end

          { status: :received }
        end

        def expected_resource_type(event_name)
          PAYMENT_EVENTS.include?(event_name) ? "subscription-invoices" : "subscriptions"
        end

        def terminal_disposition(status, reason_code)
          {
            status: status,
            processed_at: @now,
            error_code: (reason_code if status == :quarantined),
            reason_code: reason_code
          }
        end

        def provider_id(value)
          safe_value(value, maximum: 128, pattern: SAFE_PROVIDER_ID)
        end

        def nested_value(value, *keys)
          keys.each do |key|
            return unless value.is_a?(Hash)

            value = value[key]
          end
          value
        end

        def safe_request_id(value)
          normalized = value.to_s
          return "unavailable" unless /\A[a-zA-Z0-9-]{1,255}\z/.match?(normalized)

          normalized
        end

        def log_quarantine(event)
          Rails.logger.warn(
            "billing_webhook_quarantined event_id=#{event.id} " \
              "reason_code=#{event.error_code} request_id=#{@request_id}"
          )
        end

        def safe_value(value, maximum:, pattern:)
          return unless value.is_a?(String) || value.is_a?(Integer)

          normalized = value.to_s.strip
          return if normalized.empty? || normalized.bytesize > maximum

          normalized if pattern.match?(normalized)
        end

        def bounded_scalar(value)
          return if value.nil?
          return unless value.is_a?(String)

          normalized = value.strip
          return if normalized.empty? || normalized.bytesize > 64 || normalized.match?(/[[:cntrl:]]/)

          normalized
        end

        def boolean_value(value)
          value if value == true || value == false
        end

        def trusted_test_mode(value)
          value if (@environment == "test" && value == true) || (@environment == "live" && value == false)
        end
    end
  end
end
