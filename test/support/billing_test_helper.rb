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
    plan_price ||= create_test_plan_price(
      plan: create_test_plan,
      lemon_store_id: provider_numeric_id,
      lemon_product_id: provider_numeric_id,
      lemon_variant_id: provider_numeric_id
    )
    environment = overrides.fetch(:environment, "test").to_s
    create_billing_provider_price_mapping(
      plan_price: plan_price,
      environment: environment
    ) unless plan_price.billing_provider_price_mappings.exists?(
      provider: "lemon_squeezy",
      environment: environment
    )

    organization.billing_checkout_attempts.create!({
      initiated_by_membership: membership,
      plan_price: plan_price,
      provider: "lemon_squeezy",
      environment: environment,
      test_mode: environment == "test",
      token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
      status: "creating",
      expires_at: 30.minutes.from_now
    }.merge(overrides))
  end

  def create_billing_provider_price_mapping(plan_price:, environment: "test", **overrides)
    if plan_price.lemon_variant_id.blank?
      plan_price.update!(
        lemon_store_id: provider_numeric_id,
        lemon_product_id: provider_numeric_id,
        lemon_variant_id: provider_numeric_id
      )
    end

    Billing::ProviderPriceMapping.create!({
      plan_price: plan_price,
      provider: "lemon_squeezy",
      environment: environment,
      provider_store_id: plan_price.lemon_store_id,
      provider_product_id: plan_price.lemon_product_id,
      provider_variant_id: plan_price.lemon_variant_id,
      active: true
    }.merge(overrides))
  end

  def create_billing_provider_locator(organization:, checkout_attempt:, **overrides)
    organization.billing_provider_locators.create!({
      checkout_attempt: checkout_attempt,
      provider: checkout_attempt.provider,
      environment: checkout_attempt.environment,
      token_digest: checkout_attempt.token_digest,
      status: :unresolved
    }.merge(overrides))
  end

  def create_billing_webhook_event(**overrides)
    now = Time.current
    receipt_time = [ now, overrides[:processed_at] ].compact.min
    Billing::WebhookEvent.create!({
      provider: "lemon_squeezy",
      environment: "test",
      fingerprint: Digest::SHA256.hexdigest(SecureRandom.hex(32)),
      status: "received",
      test_mode: true,
      ingress_version: Billing::WebhookEvent::CURRENT_INGRESS_VERSION,
      received_at: receipt_time,
      verified_at: receipt_time,
      snapshot: {}
    }.merge(overrides))
  end

  private
    def provider_numeric_id
      SecureRandom.random_number(8_999_999_999_999_999).then { |value| (value + 1_000_000_000_000_000).to_s }
    end
end
