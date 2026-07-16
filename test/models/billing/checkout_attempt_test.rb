require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::CheckoutAttemptTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "stores only a digest and requires the initiating membership tenant" do
    organization, membership = create_billing_tenant(prefix: "checkout")
    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )

    assert_match(/\A[0-9a-f]{64}\z/, attempt.token_digest)
    assert_not_includes Billing::CheckoutAttempt.column_names, "token"
    assert_not_includes Billing::CheckoutAttempt.column_names, "provider_checkout_url"
  end

  test "rejects a membership from another organization" do
    organization, = create_billing_tenant(prefix: "checkout-local")
    _, foreign_membership = create_billing_tenant(prefix: "checkout-foreign")
    attempt = organization.billing_checkout_attempts.new(
      initiated_by_membership: foreign_membership,
      plan_price: create_test_plan_price(plan: create_test_plan),
      provider: "lemon_squeezy",
      environment: "test",
      test_mode: true,
      token_digest: Digest::SHA256.hexdigest("foreign-membership"),
      status: "creating",
      expires_at: 30.minutes.from_now
    )

    assert_not attempt.valid?
    assert_includes attempt.errors[:initiated_by_membership], "must belong to the organization"
  end

  test "requires lifecycle metadata for ready completed and failed states" do
    organization, membership = create_billing_tenant(prefix: "checkout-lifecycle")
    attempt = organization.billing_checkout_attempts.new(
      initiated_by_membership: membership,
      plan_price: create_test_plan_price(plan: create_test_plan),
      provider: "lemon_squeezy",
      environment: "test",
      test_mode: true,
      token_digest: Digest::SHA256.hexdigest("lifecycle"),
      status: "ready",
      expires_at: 30.minutes.from_now
    )

    assert_not attempt.valid?
    assert_includes attempt.errors[:provider_checkout_id], "must be present"

    attempt.assign_attributes(status: "failed", completed_at: Time.current)
    assert_not attempt.valid?
    assert_includes attempt.errors[:failure_code], "must be present"
  end
end
