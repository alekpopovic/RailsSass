require "openssl"

module Billing
  module Webhooks
    class SignatureVerifier
      SIGNATURE_PATTERN = /\A[0-9a-f]{64}\z/

      def initialize(secret:, previous_secret: nil, previous_secret_expires_at: nil)
        @secret = secret.to_s
        @previous_secret = previous_secret.to_s
        @previous_secret_expires_at = previous_secret_expires_at
      end

      def configured?
        @secret.present?
      end

      def valid?(raw_body:, signature:, now: Time.current)
        !verify(raw_body: raw_body, signature: signature, now: now).nil?
      end

      def verify(raw_body:, signature:, now: Time.current)
        supplied_signature = signature.to_s
        return unless configured? && SIGNATURE_PATTERN.match?(supplied_signature)

        matches = eligible_secrets(now: now).map do |slot, secret|
          expected_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
          [
            slot,
            ActiveSupport::SecurityUtils.secure_compare(expected_signature, supplied_signature)
          ]
        end
        matches.find { |_slot, matched| matched }&.first
      end

      private
        def eligible_secrets(now:)
          secrets = [ [ :current, @secret ] ]
          secrets << [ :previous, @previous_secret ] if previous_secret_active?(now: now)
          secrets
        end

        def previous_secret_active?(now:)
          @previous_secret.present? &&
            @previous_secret != @secret &&
            @previous_secret_expires_at.respond_to?(:>) &&
            @previous_secret_expires_at > now
        end
    end
  end
end
