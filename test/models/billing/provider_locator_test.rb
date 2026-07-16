require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::ProviderLocatorTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "stores only the digest identity for a tenant checkout attempt" do
    organization, membership = create_billing_tenant(prefix: "provider-locator")
    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )
    locator = create_billing_provider_locator(
      organization: organization,
      checkout_attempt: attempt
    )

    assert_predicate locator, :status_unresolved?
    assert_equal attempt.token_digest, locator.token_digest
    assert_not_includes Billing::ProviderLocator.column_names, "token"
    assert_not_includes Billing::ProviderLocator.column_names, "nonce"
  end

  test "rejects a checkout attempt from another organization" do
    local_organization, = create_billing_tenant(prefix: "provider-locator-local")
    foreign_organization, foreign_membership = create_billing_tenant(prefix: "provider-locator-foreign")
    foreign_attempt = create_billing_checkout_attempt(
      organization: foreign_organization,
      membership: foreign_membership
    )
    locator = local_organization.billing_provider_locators.new(
      checkout_attempt: foreign_attempt,
      provider: foreign_attempt.provider,
      environment: foreign_attempt.environment,
      token_digest: foreign_attempt.token_digest,
      status: :unresolved
    )

    assert_not locator.valid?
    assert_includes locator.errors[:checkout_attempt], "must match the provider locator identity"
  end

  test "resolved locator status requires a timestamp" do
    organization, membership = create_billing_tenant(prefix: "provider-locator-state")
    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )
    locator = organization.billing_provider_locators.new(
      checkout_attempt: attempt,
      provider: attempt.provider,
      environment: attempt.environment,
      token_digest: attempt.token_digest,
      status: :definitive_creation_failure
    )

    assert_not locator.valid?
    assert_includes locator.errors[:resolved_at], "must be present"
  end

  test "consumed locator binds one matching tenant subscription identity" do
    organization, membership = create_billing_tenant(prefix: "provider-locator-subscription")
    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )
    locator = create_billing_provider_locator(
      organization: organization,
      checkout_attempt: attempt
    )
    subscription = create_billing_subscription(
      organization: organization,
      plan_price: attempt.plan_price,
      origin_checkout_attempt: attempt
    )

    locator.update!(
      status: :consumed,
      resolved_at: Time.current,
      provider_subscription_id: subscription.provider_subscription_id,
      billing_subscription: subscription
    )

    assert_equal subscription, locator.billing_subscription
    assert_equal locator, subscription.provider_locator

    locator.provider_subscription_id = "different_subscription"
    assert_not locator.valid?
    assert_includes locator.errors[:provider_subscription_id], "cannot change after resolution"
  end

  test "consumed locator rejects cross-tenant subscription binding" do
    organization, membership = create_billing_tenant(prefix: "provider-locator-binding-local")
    foreign_organization, = create_billing_tenant(prefix: "provider-locator-binding-foreign")
    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )
    foreign_subscription = create_billing_subscription(organization: foreign_organization)
    locator = organization.billing_provider_locators.new(
      checkout_attempt: attempt,
      provider: attempt.provider,
      environment: attempt.environment,
      token_digest: attempt.token_digest,
      status: :consumed,
      resolved_at: Time.current,
      provider_subscription_id: foreign_subscription.provider_subscription_id,
      billing_subscription: foreign_subscription
    )

    assert_not locator.valid?
    assert_includes locator.errors[:billing_subscription],
      "must match the provider subscription identity"
  end

  test "consumed locator rejects a subscription originated by another checkout attempt" do
    organization, membership = create_billing_tenant(prefix: "provider-locator-origin")
    locator_attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership
    )
    other_attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership,
      status: :failed,
      completed_at: 1.second.from_now,
      failure_code: "provider_rejected"
    )
    subscription = create_billing_subscription(
      organization: organization,
      plan_price: other_attempt.plan_price,
      origin_checkout_attempt: other_attempt
    )
    locator = organization.billing_provider_locators.new(
      checkout_attempt: locator_attempt,
      provider: locator_attempt.provider,
      environment: locator_attempt.environment,
      token_digest: locator_attempt.token_digest,
      status: :consumed,
      resolved_at: Time.current,
      provider_subscription_id: subscription.provider_subscription_id,
      billing_subscription: subscription
    )

    assert_not locator.valid?
    assert_includes locator.errors[:billing_subscription],
      "must match the provider subscription identity"
  end
end
