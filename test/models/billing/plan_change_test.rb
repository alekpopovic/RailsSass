require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::PlanChangeTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "records intent without changing local subscription state" do
    organization, membership = create_billing_tenant(prefix: "plan-change")
    from_price = create_test_plan_price(plan: create_test_plan)
    to_price = create_test_plan_price(plan: create_test_plan)
    subscription = create_billing_subscription(
      organization: organization,
      plan_price: from_price
    )

    plan_change = organization.billing_plan_changes.create!(
      billing_subscription: subscription,
      requested_by_membership: membership,
      from_plan_price: from_price,
      to_plan_price: to_price,
      provider: subscription.provider,
      environment: subscription.environment,
      test_mode: subscription.test_mode,
      status: "pending",
      requested_at: Time.current
    )

    assert_predicate plan_change, :status_pending?
    assert_equal from_price, subscription.reload.plan_price
    assert_equal "active", subscription.status
  end

  test "requires different prices and matching tenant relationships" do
    organization, membership = create_billing_tenant(prefix: "plan-change-local")
    foreign_organization, foreign_membership = create_billing_tenant(prefix: "plan-change-foreign")
    price = create_test_plan_price(plan: create_test_plan)
    foreign_subscription = create_billing_subscription(organization: foreign_organization)
    plan_change = organization.billing_plan_changes.new(
      billing_subscription: foreign_subscription,
      requested_by_membership: foreign_membership,
      from_plan_price: price,
      to_plan_price: price,
      provider: "lemon_squeezy",
      environment: "test",
      test_mode: true,
      status: "pending",
      requested_at: Time.current
    )

    assert_not plan_change.valid?
    assert_includes plan_change.errors[:billing_subscription], "must match the tenant and provider identity"
    assert_includes plan_change.errors[:requested_by_membership], "must belong to the organization"
    assert_includes plan_change.errors[:to_plan_price], "must differ from the current price"
  end

  test "requires the current subscription and its captured source price on creation" do
    organization, membership = create_billing_tenant(prefix: "plan-change-source")
    current_price = create_test_plan_price(plan: create_test_plan)
    other_price = create_test_plan_price(plan: create_test_plan)
    target_price = create_test_plan_price(plan: create_test_plan)
    subscription = create_billing_subscription(
      organization: organization,
      plan_price: current_price
    )
    subscription.update!(current: false, archived_at: Time.current)
    plan_change = organization.billing_plan_changes.new(
      billing_subscription: subscription,
      requested_by_membership: membership,
      from_plan_price: other_price,
      to_plan_price: target_price,
      provider: subscription.provider,
      environment: subscription.environment,
      test_mode: subscription.test_mode,
      status: "pending",
      requested_at: Time.current
    )

    assert_not plan_change.valid?
    assert_includes plan_change.errors[:billing_subscription],
      "must be current when the change is requested"
    assert_includes plan_change.errors[:from_plan_price],
      "must match the subscription price"
  end
end
