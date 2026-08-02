require "test_helper"
require_relative "../../../support/billing_test_helper"

class Billing::Portals::OpenTest < ActiveSupport::TestCase
  include BillingTestHelper

  FakeClient = Struct.new(:environment, :calls, keyword_init: true) do
    def test_mode?
      environment == "test"
    end

    def retrieve_customer_portal_url(**attributes)
      calls << attributes
      "https://provider.example.test/billing"
    end
  end

  setup do
    @organization, @membership = create_billing_tenant(prefix: "portal-service")
    @user = @membership.user
    establish_tenant_context(
      user: @user,
      organization: @organization,
      membership: @membership
    )
    plan_price = create_test_plan_price(plan: create_test_plan)
    @subscription = create_billing_subscription(
      organization: @organization,
      plan_price: plan_price,
      environment: "test",
      test_mode: true
    )
    @client = FakeClient.new(environment: "test", calls: [])
  end

  teardown do
    Current.reset
  end

  test "a revoked Current session cannot request a portal URL or mutate billing state" do
    subscription_attributes = @subscription.attributes
    Session.where(id: Current.session.id).delete_all

    assert_no_difference [
      -> { Billing::Subscription.count },
      -> { Billing::PlanChange.count },
      -> { @organization.audit_events.count }
    ] do
      assert_raises(Pundit::NotAuthorizedError) do
        Billing::Portals::Open.new(
          organization: @organization,
          user: @user,
          client: @client
        ).call
      end
    end

    assert_empty @client.calls
    assert_equal subscription_attributes, @subscription.reload.attributes
  end
end
