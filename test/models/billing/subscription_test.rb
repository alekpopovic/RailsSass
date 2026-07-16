require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::SubscriptionTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "preserves archived history while exposing one tenant-scoped current row" do
    organization, = create_billing_tenant(prefix: "subscription-history")
    customer = create_billing_customer(organization: organization)
    archived = create_billing_subscription(
      organization: organization,
      billing_customer: customer
    )
    archived.update!(current: false, archived_at: Time.current)
    current = create_billing_subscription(
      organization: organization,
      billing_customer: customer
    )

    assert_equal [ archived, current ], organization.billing_subscriptions.order(:id).to_a
    assert_equal current, organization.billing_subscriptions.find_by!(current: true)
    assert_predicate archived, :persisted?
  end

  test "requires customer tenant provider and test mode identity to match" do
    organization, = create_billing_tenant(prefix: "subscription-local")
    foreign_organization, = create_billing_tenant(prefix: "subscription-foreign")
    foreign_customer = create_billing_customer(organization: foreign_organization)
    subscription = organization.billing_subscriptions.new(
      billing_customer: foreign_customer,
      plan_price: create_test_plan_price(plan: create_test_plan),
      provider: "lemon_squeezy",
      environment: "test",
      provider_subscription_id: "subscription_cross_tenant",
      provider_customer_id: foreign_customer.provider_customer_id,
      status: "active",
      current: true,
      provider_updated_at: Time.current,
      test_mode: true
    )

    assert_not subscription.valid?
    assert_includes subscription.errors[:billing_customer], "must match the tenant and provider identity"
  end

  test "requires status timestamps card pairing and current archive consistency" do
    organization, = create_billing_tenant(prefix: "subscription-lifecycle")
    customer = create_billing_customer(organization: organization)
    subscription = Billing::Subscription.new(
      organization: organization,
      billing_customer: customer,
      plan_price: create_test_plan_price(plan: create_test_plan),
      provider: "lemon_squeezy",
      environment: "test",
      provider_subscription_id: "subscription_invalid_lifecycle",
      provider_customer_id: customer.provider_customer_id,
      status: "on_trial",
      current: false,
      provider_updated_at: Time.current,
      test_mode: true,
      card_brand: "visa"
    )

    assert_not subscription.valid?
    assert_includes subscription.errors[:trial_ends_at], "must be present"
    assert_includes subscription.errors[:archived_at], "must be blank only for the current subscription"
    assert_includes subscription.errors[:card_last_four], "must be provided with card brand"
  end

  test "rejects raw or sensitive diagnostic payloads recursively" do
    organization, = create_billing_tenant(prefix: "subscription-payload")
    customer = create_billing_customer(organization: organization)
    subscription = Billing::Subscription.new(
      organization: organization,
      billing_customer: customer,
      plan_price: create_test_plan_price(plan: create_test_plan),
      provider: "lemon_squeezy",
      environment: "test",
      provider_subscription_id: "subscription_sensitive_payload",
      provider_customer_id: customer.provider_customer_id,
      status: "active",
      current: true,
      provider_updated_at: Time.current,
      test_mode: true,
      raw_payload: { "data" => { "attributes" => { "customer_email" => "private@example.test" } } }
    )

    assert_not subscription.valid?
    assert_includes subscription.errors[:raw_payload], "contains a sensitive field"

    %w[user_email userEmail accessToken cardNumber].each do |sensitive_key|
      subscription.raw_payload = { sensitive_key => "private-value" }
      assert_not subscription.valid?
      assert_includes subscription.errors[:raw_payload], "contains a sensitive field"
    end

    subscription.raw_payload = { "contact" => "private@example.test" }
    assert_not subscription.valid?
    assert_includes subscription.errors[:raw_payload], "contains an unsupported field"

    subscription.raw_payload = [ "not", "an", "object" ]
    assert_not subscription.valid?
    assert_includes subscription.errors[:raw_payload], "must be an object"

    subscription.raw_payload = { "status" => "x" * 65_537 }
    assert_not subscription.valid?
    assert_includes subscription.errors[:raw_payload], "must be at most 64 KiB"

    subscription.raw_payload = {}
    subscription.pause = { "user_email" => "private@example.test" }
    assert_not subscription.valid?
    assert_includes subscription.errors[:pause], "contains a sensitive field"
  end

  test "archival is one way and subscription history cannot be destroyed" do
    organization, = create_billing_tenant(prefix: "subscription-immutable-history")
    subscription = create_billing_subscription(organization: organization)
    subscription.update!(current: false, archived_at: Time.current)

    subscription.assign_attributes(current: true, archived_at: nil)
    assert_not subscription.valid?
    assert_includes subscription.errors[:current], "cannot reactivate archived history"
    assert_includes subscription.errors[:archived_at], "cannot change after archival"

    subscription.reload
    assert_raises(ActiveRecord::RecordNotDestroyed) { subscription.destroy! }
    assert_predicate subscription.reload, :persisted?
  end
end
