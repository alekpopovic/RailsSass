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
end
