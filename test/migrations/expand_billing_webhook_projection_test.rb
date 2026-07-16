require "test_helper"
require_relative "../support/billing_test_helper"

class ExpandBillingWebhookProjectionTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "subscription projection columns are constrained and indexed" do
    columns = Billing::Subscription.columns_hash

    %w[last_seen_provider_updated_at sync_state origin_plan_price_id].each do |name|
      assert_not columns.fetch(name).null
    end
    assert_predicate columns.fetch("origin_checkout_attempt_id"), :null
    assert_equal "synced", columns.fetch("sync_state").default

    constraints = Billing::Subscription.connection
      .check_constraints(:billing_subscriptions)
      .index_by(&:name)
    assert constraints.key?("billing_subscriptions_sync_state_allowed")
    assert constraints.key?("billing_subscriptions_seen_update_monotonic")

    indexes = Billing::Subscription.connection.indexes(:billing_subscriptions).index_by(&:name)
    origin_index = indexes.fetch("index_billing_subscriptions_on_origin_checkout_attempt")
    assert_predicate origin_index, :unique
    assert_match(/origin_checkout_attempt_id IS NOT NULL/i, origin_index.where)
    assert indexes.key?("index_billing_subscriptions_on_sync_reconciliation")
    origin_locator = indexes.fetch("index_billing_subscriptions_on_origin_locator_identity")
    assert_predicate origin_locator, :unique
  end

  test "composite foreign keys bind subscription origins and provider locators to one tenant" do
    subscription_keys = Billing::Subscription.connection.foreign_keys(:billing_subscriptions)
    locator_keys = Billing::ProviderLocator.connection.foreign_keys(:billing_provider_locators)

    assert subscription_keys.any? { |key|
      key.name == "fk_billing_subscriptions_origin_checkout_identity" &&
        key.column == %w[
          origin_checkout_attempt_id organization_id origin_plan_price_id provider environment
        ]
    }
    assert locator_keys.any? { |key|
        key.name == "fk_billing_provider_locators_subscription_identity" &&
        key.column == %w[
          billing_subscription_id organization_id provider environment provider_subscription_id
          billing_checkout_attempt_id
        ]
    }
    assert (subscription_keys + locator_keys).all? { |key| key.on_delete == :restrict }
  end

  test "provider subscription locator identity is unique and lifecycle constrained" do
    columns = Billing::ProviderLocator.columns_hash
    assert_predicate columns.fetch("provider_subscription_id"), :null
    assert_predicate columns.fetch("billing_subscription_id"), :null

    indexes = Billing::ProviderLocator.connection
      .indexes(:billing_provider_locators)
      .index_by(&:name)
    provider_identity = indexes.fetch("index_billing_provider_locators_on_subscription_identity")
    subscription_binding = indexes.fetch("index_billing_provider_locators_on_billing_subscription")
    assert_predicate provider_identity, :unique
    assert_predicate subscription_binding, :unique
    assert_match(/provider_subscription_id IS NOT NULL/i, provider_identity.where)
    assert_match(/billing_subscription_id IS NOT NULL/i, subscription_binding.where)

    constraints = Billing::ProviderLocator.connection
      .check_constraints(:billing_provider_locators)
      .index_by(&:name)
    assert_not_equal false,
      constraints.fetch("billing_provider_locators_lifecycle").options[:validate]
    assert constraints.key?("billing_provider_locators_subscription_id_normalized")
  end

  test "only current signed-ingress rows carry the projection authority marker" do
    column = Billing::WebhookEvent.columns_hash.fetch("ingress_version")
    assert_predicate column, :null

    constraints = Billing::WebhookEvent.connection
      .check_constraints(:billing_webhook_events)
      .index_by(&:name)
    assert constraints.key?("billing_webhook_events_ingress_version_allowed")

    indexes = Billing::WebhookEvent.connection
      .indexes(:billing_webhook_events)
      .index_by(&:name)
    assert indexes.key?("index_billing_webhook_events_on_verified_recovery")
  end
end
