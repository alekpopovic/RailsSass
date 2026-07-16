require "test_helper"
require_relative "../../../support/billing_test_helper"

class Billing::Checkouts::TokenTest < ActiveSupport::TestCase
  include BillingTestHelper

  setup do
    @user = create_test_user(email_address: "checkout-token-#{SecureRandom.hex(4)}@example.test")
    @organization, = create_test_organization_with_owner(
      owner: @user,
      name: "Checkout Token Organization",
      slug: "checkout-token-#{SecureRandom.hex(4)}"
    )
    @plan_price = create_test_plan_price(plan: create_test_plan)
  end

  test "signed payload contains only required correlation fields and verifies before expiry" do
    now = Time.current.change(usec: 0)
    nonce = described_class.generate_nonce
    token = described_class.issue(
      organization: @organization,
      plan_price: @plan_price,
      user: @user,
      nonce: nonce,
      expires_at: now + 15.minutes
    )

    payload = described_class.verify(token, now: now)

    assert_equal @organization.public_id, payload.organization_public_id
    assert_equal @plan_price.id, payload.plan_price_id
    assert_equal @user.id, payload.user_id
    assert_equal nonce, payload.nonce
    assert_equal now + 15.minutes, payload.expires_at
    assert_equal Digest::SHA256.hexdigest(nonce), described_class.digest_nonce(nonce)
    assert_not_includes token, nonce
  end

  test "tampered expired and wrong-purpose payloads fail closed" do
    now = Time.current.change(usec: 0)
    token = described_class.issue(
      organization: @organization,
      plan_price: @plan_price,
      user: @user,
      expires_at: now + 1.minute
    )
    tampered = token.dup
    tampered[-1] = tampered[-1] == "a" ? "b" : "a"
    wrong_purpose = Rails.application.message_verifier("billing_checkout").generate(
      { "organization_public_id" => @organization.public_id },
      expires_at: now + 1.minute,
      purpose: "different-purpose"
    )

    assert_nil described_class.verify(tampered, now: now)
    assert_nil described_class.verify(wrong_purpose, now: now)
    travel_to(now + 2.minutes) do
      assert_nil described_class.verify(token)
    end
  end

  private
    def described_class
      Billing::Checkouts::Token
    end
end
