require "digest"
require "securerandom"

module Billing
  module Checkouts
    class Token
      PURPOSE = "billing_checkout_attempt"
      NONCE_BYTES = 32
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      NONCE_PATTERN = /\A[A-Za-z0-9_-]{43,128}\z/

      Payload = Data.define(
        :organization_public_id,
        :plan_price_id,
        :user_id,
        :nonce,
        :expires_at
      )

      class << self
        def issue(organization:, plan_price:, user:, expires_at:, nonce: generate_nonce, verifier: default_verifier)
          expiry = expires_at.to_time
          payload = {
            "organization_public_id" => organization.public_id,
            "plan_price_id" => plan_price.id,
            "user_id" => user.id,
            "nonce" => nonce,
            "expires_at" => expiry.to_i
          }

          verifier.generate(payload, expires_at: expiry, purpose: PURPOSE)
        end

        def verify(raw_token, now: Time.current, verifier: default_verifier)
          attributes = verifier.verified(raw_token.to_s, purpose: PURPOSE)
          return unless attributes.is_a?(Hash)

          payload = build_payload(attributes)
          return unless payload && payload.expires_at > now

          payload
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          nil
        end

        def generate_nonce
          SecureRandom.urlsafe_base64(NONCE_BYTES)
        end

        def digest_nonce(nonce)
          Digest::SHA256.hexdigest(nonce.to_s)
        end

        private
          def default_verifier
            Rails.application.message_verifier("billing_checkout")
          end

          def build_payload(attributes)
            values = attributes.stringify_keys
            organization_public_id = values["organization_public_id"].to_s
            nonce = values["nonce"].to_s
            plan_price_id = Integer(values["plan_price_id"].to_s, 10)
            user_id = Integer(values["user_id"].to_s, 10)
            expires_at = Time.at(Integer(values["expires_at"].to_s, 10)).utc

            return unless UUID_PATTERN.match?(organization_public_id)
            return unless NONCE_PATTERN.match?(nonce)
            return unless plan_price_id.positive? && user_id.positive?

            Payload.new(
              organization_public_id: organization_public_id,
              plan_price_id: plan_price_id,
              user_id: user_id,
              nonce: nonce,
              expires_at: expires_at
            )
          rescue ArgumentError, TypeError
            nil
          end
      end
    end
  end
end
