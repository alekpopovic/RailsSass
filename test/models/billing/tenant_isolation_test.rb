require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::TenantIsolationTest < ActiveSupport::TestCase
  include BillingTestHelper

  teardown do
    Current.reset
  end

  test "foreign tenant billing records cannot be read changed or deleted through Current organization" do
    organization, membership = create_billing_tenant(prefix: "billing-isolation")
    foreign_organization, foreign_membership = create_billing_tenant(prefix: "billing-isolation-foreign")
    foreign_customer = create_billing_customer(organization: foreign_organization)
    foreign_price = create_test_plan_price(plan: create_test_plan)
    foreign_subscription = create_billing_subscription(
      organization: foreign_organization,
      billing_customer: foreign_customer,
      plan_price: foreign_price
    )
    foreign_attempt = create_billing_checkout_attempt(
      organization: foreign_organization,
      membership: foreign_membership
    )
    foreign_plan_change = foreign_organization.billing_plan_changes.create!(
      billing_subscription: foreign_subscription,
      requested_by_membership: foreign_membership,
      from_plan_price: foreign_price,
      to_plan_price: create_test_plan_price(plan: create_test_plan),
      provider: foreign_subscription.provider,
      environment: foreign_subscription.environment,
      test_mode: foreign_subscription.test_mode,
      status: "pending",
      requested_at: Time.current
    )
    user = membership.user
    establish_tenant_context(
      user: user,
      organization: organization,
      membership: membership
    )

    foreign_records = {
      billing_customers: foreign_customer,
      billing_checkout_attempts: foreign_attempt,
      billing_subscriptions: foreign_subscription,
      billing_plan_changes: foreign_plan_change
    }
    foreign_records.each do |association_name, record|
      scope = Current.organization.public_send(association_name)

      assert_raises(ActiveRecord::RecordNotFound) { scope.find(record.id) }
      assert_raises(ActiveRecord::RecordNotFound) do
        scope.find(record.id).update!(updated_at: Time.current)
      end
      assert_raises(ActiveRecord::RecordNotFound) { scope.find(record.id).destroy! }
    end

    assert_predicate foreign_subscription.reload, :current?
    assert_predicate foreign_attempt.reload, :status_creating?
    assert_predicate foreign_plan_change.reload, :status_pending?
  end
end
