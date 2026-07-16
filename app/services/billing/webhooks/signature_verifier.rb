require "openssl"

module Billing
  module Webhooks
    class SignatureVerifier
      SIGNATURE_PATTERN = /\A[0-9a-f]{64}\z/

      def initialize(secret:)
        @secret = secret.to_s
      end

      def configured?
        @secret.present?
      end

      def valid?(raw_body:, signature:)
        supplied_signature = signature.to_s
        return false unless configured? && SIGNATURE_PATTERN.match?(supplied_signature)

        expected_signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, raw_body)
        ActiveSupport::SecurityUtils.secure_compare(expected_signature, supplied_signature)
      end
    end
  end
end
