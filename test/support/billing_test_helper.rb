require "digest"
require_relative "organization_test_helper"
require_relative "catalog_test_helper"

module BillingTestHelper
  include OrganizationTestHelper
  include CatalogTestHelper

  def create_billing_tenant(prefix: "billing")
    suffix = SecureRandom.hex(6)
    user = create_test_user(email_address: "#{prefix}-#{suffix}@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: user,
      name: "#{prefix.titleize} Tenant",
      slug: "#{prefix.parameterize}-#{suffix}"
    )

    [ organization, membership ]
  end

  def create_billing_customer(organization:, **overrides)
    organization.billing_customers.create!({
      provider: "lemon_squeezy",
      environment: "test",
      provider_customer_id: "customer_#{SecureRandom.hex(8)}",
      test_mode: true,
      provider_updated_at: Time.current
    }.merge(overrides))
  end

  def create_billing_subscription(organization:, billing_customer: nil, plan_price: nil, **overrides)
    billing_customer ||= create_billing_customer(organization: organization)
    plan_price ||= create_test_plan_price(plan: create_test_plan)
    attributes = {
      billing_customer: billing_customer,
      plan_price: plan_price,
      provider: "lemon_squeezy",
      environment: billing_customer.environment,
      provider_subscription_id: "subscription_#{SecureRandom.hex(8)}",
      provider_customer_id: billing_customer.provider_customer_id,
      status: "active",
      current: true,
      provider_updated_at: Time.current,
      pause: {},
      test_mode: billing_customer.test_mode,
      raw_payload: {},
      archived_at: nil
    }.merge(overrides)
    if attributes[:status].to_s == "past_due" && !overrides.key?(:past_due_started_at)
      attributes[:past_due_started_at] = attributes[:provider_updated_at]
    end

    organization.billing_subscriptions.create!(attributes)
  end

  def create_billing_checkout_attempt(organization:, membership:, plan_price: nil, **overrides)
    plan_price ||= create_test_plan_price(plan: create_test_plan)

    organization.billing_checkout_attempts.create!({
      initiated_by_membership: membership,
      plan_price: plan_price,
      provider: "lemon_squeezy",
      environment: "test",
      test_mode: true,
      token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
      status: "creating",
      expires_at: 30.minutes.from_now
    }.merge(overrides))
  end

  def create_billing_webhook_event(**overrides)
    now = Time.current
    Billing::WebhookEvent.create!({
      provider: "lemon_squeezy",
      environment: "test",
      fingerprint: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
      status: "received",
      test_mode: true,
      received_at: now,
      verified_at: now,
      snapshot: {}
    }.merge(overrides))
  end
end
