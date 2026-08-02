require "test_helper"
require "openssl"

class Billing::Webhooks::SignatureVerifierTest < ActiveSupport::TestCase
  CURRENT_SECRET = "synthetic-current-webhook-secret"
  PREVIOUS_SECRET = "synthetic-previous-webhook-secret"
  RAW_BODY = %({"event":"synthetic"})
  NOW = Time.utc(2026, 8, 2, 12, 0, 0)

  test "accepts current and unexpired previous signatures" do
    verifier = verifier_with_previous(expires_at: NOW + 1.hour)

    assert_equal :current, verifier.verify(
      raw_body: RAW_BODY,
      signature: signature_for(CURRENT_SECRET),
      now: NOW
    )
    assert_equal :previous, verifier.verify(
      raw_body: RAW_BODY,
      signature: signature_for(PREVIOUS_SECRET),
      now: NOW
    )
    assert_equal true, verifier.valid?(
      raw_body: RAW_BODY,
      signature: signature_for(CURRENT_SECRET),
      now: NOW
    )
  end

  test "rejects the previous signature at its expiry while retaining the current key" do
    verifier = verifier_with_previous(expires_at: NOW)

    assert_equal false, verifier.valid?(
      raw_body: RAW_BODY,
      signature: signature_for(PREVIOUS_SECRET),
      now: NOW
    )
    assert_equal true, verifier.valid?(
      raw_body: RAW_BODY,
      signature: signature_for(CURRENT_SECRET),
      now: NOW
    )
  end

  test "does not use a partial or duplicate previous-key configuration" do
    verifiers = [
      Billing::Webhooks::SignatureVerifier.new(
        secret: CURRENT_SECRET,
        previous_secret: PREVIOUS_SECRET
      ),
      Billing::Webhooks::SignatureVerifier.new(
        secret: CURRENT_SECRET,
        previous_secret: CURRENT_SECRET,
        previous_secret_expires_at: NOW + 1.hour
      )
    ]

    verifiers.each do |verifier|
      assert_equal false, verifier.valid?(
        raw_body: RAW_BODY,
        signature: signature_for(PREVIOUS_SECRET),
        now: NOW
      )
    end
  end

  test "computes every eligible HMAC even when the current key matches" do
    verifier = verifier_with_previous(expires_at: NOW + 1.hour)
    original_hexdigest = OpenSSL::HMAC.method(:hexdigest)
    evaluated_secrets = []
    calculate = lambda do |algorithm, secret, body|
      evaluated_secrets << secret
      original_hexdigest.call(algorithm, secret, body)
    end

    OpenSSL::HMAC.define_singleton_method(:hexdigest, calculate)
    begin
      assert_equal true, verifier.valid?(
        raw_body: RAW_BODY,
        signature: signature_for(CURRENT_SECRET, hexdigest: original_hexdigest),
        now: NOW
      )
    ensure
      OpenSSL::HMAC.define_singleton_method(:hexdigest, original_hexdigest)
    end

    assert_equal [ CURRENT_SECRET, PREVIOUS_SECRET ], evaluated_secrets
  end

  private
    def verifier_with_previous(expires_at:)
      Billing::Webhooks::SignatureVerifier.new(
        secret: CURRENT_SECRET,
        previous_secret: PREVIOUS_SECRET,
        previous_secret_expires_at: expires_at
      )
    end

    def signature_for(secret, hexdigest: OpenSSL::HMAC.method(:hexdigest))
      hexdigest.call("SHA256", secret, RAW_BODY)
    end
end
