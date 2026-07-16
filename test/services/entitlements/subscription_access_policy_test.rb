require "test_helper"
require_relative "../../support/billing_test_helper"

class Entitlements::SubscriptionAccessPolicyTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "allows trial and active statuses and fails closed for blocked or unknown statuses" do
    organization, = create_billing_tenant(prefix: "entitlement-policy-matrix")
    subscription = create_billing_subscription(organization: organization)
    now = Time.current
    expectations = {
      "on_trial" => [ true, :subscription_on_trial ],
      "active" => [ true, :subscription_active ],
      "paused" => [ false, :subscription_paused ],
      "unpaid" => [ false, :subscription_unpaid ],
      "expired" => [ false, :subscription_expired ],
      "unknown" => [ false, :subscription_unknown_status ]
    }

    expectations.each do |status, (allowed, reason_code)|
      subscription.assign_attributes(
        status: status,
        trial_ends_at: status == "on_trial" ? now - 1.day : nil,
        ends_at: nil,
        past_due_started_at: nil
      )
      result = policy(subscription, now: now).call

      assert_equal allowed, result.allowed?, "unexpected access for #{status}"
      assert_equal reason_code, result.reason_code
    end
  end

  test "requires a current non-archived local subscription" do
    no_subscription = policy(nil).call

    assert_predicate no_subscription, :denied?
    assert_equal :no_current_subscription, no_subscription.reason_code

    organization, = create_billing_tenant(prefix: "entitlement-policy-history")
    subscription = create_billing_subscription(organization: organization)
    subscription.update!(current: false, archived_at: Time.current)
    archived = policy(subscription).call

    assert_predicate archived, :denied?
    assert_equal :subscription_not_current, archived.reason_code
  end

  test "fails closed while a provider snapshot is unresolved or invalid" do
    organization, = create_billing_tenant(prefix: "entitlement-policy-sync")
    subscription = create_billing_subscription(organization: organization)

    %w[pending mapping_error invalid].each do |sync_state|
      subscription.sync_state = sync_state
      result = policy(subscription).call

      assert_predicate result, :denied?
      assert_equal :subscription_sync_invalid, result.reason_code
    end
  end

  test "allows cancelled subscriptions only before the exact end boundary" do
    organization, = create_billing_tenant(prefix: "entitlement-policy-cancelled")
    subscription = create_billing_subscription(organization: organization)
    ends_at = Time.current.change(usec: 0)
    subscription.assign_attributes(status: "cancelled", ends_at: ends_at)

    before_boundary = policy(subscription, now: ends_at - Rational(1, 1_000_000)).call
    at_boundary = policy(subscription, now: ends_at).call
    after_boundary = policy(subscription, now: ends_at + 1.second).call

    assert_predicate before_boundary, :allowed?
    assert_equal :subscription_cancelled_with_access, before_boundary.reason_code
    [ at_boundary, after_boundary ].each do |result|
      assert_predicate result, :denied?
      assert_equal :subscription_cancelled_ended, result.reason_code
    end

    subscription.ends_at = nil
    missing_end = policy(subscription, now: ends_at).call
    assert_predicate missing_end, :denied?
    assert_equal :subscription_cancelled_missing_end, missing_end.reason_code
  end

  test "uses the stable past-due cycle start and configurable exact grace boundary" do
    organization, = create_billing_tenant(prefix: "entitlement-policy-past-due")
    subscription = create_billing_subscription(organization: organization)
    started_at = Time.current.change(usec: 0) - 1.day
    subscription.assign_attributes(status: "past_due", past_due_started_at: started_at)
    grace_period = 3.days
    access_ends_at = started_at + grace_period

    before_boundary = policy(
      subscription,
      now: access_ends_at - Rational(1, 1_000_000),
      past_due_grace_period: grace_period
    ).call
    at_boundary = policy(
      subscription,
      now: access_ends_at,
      past_due_grace_period: grace_period
    ).call

    assert_predicate before_boundary, :allowed?
    assert_equal :subscription_past_due_grace, before_boundary.reason_code
    assert_equal access_ends_at, before_boundary.details.fetch(:access_ends_at)
    assert_predicate at_boundary, :denied?
    assert_equal :subscription_past_due_grace_expired, at_boundary.reason_code

    subscription.past_due_started_at = started_at + 2.days
    future_start = policy(subscription, now: started_at).call
    assert_predicate future_start, :denied?
    assert_equal :subscription_past_due_future_start, future_start.reason_code

    subscription.past_due_started_at = nil
    missing_start = policy(subscription, now: started_at).call
    assert_predicate missing_start, :denied?
    assert_equal :subscription_past_due_missing_start, missing_start.reason_code
  end

  test "rejects invalid grace-period configuration" do
    [ -1, Float::INFINITY, nil, "invalid" ].each do |invalid_duration|
      assert_raises(ArgumentError) do
        policy(nil, past_due_grace_period: invalid_duration)
      end
    end
  end

  test "result owns deeply frozen copies of caller values" do
    product_key = +"core"
    nested_value = +"private-copy"
    details = { nested: [ nested_value ] }
    result = Entitlements::Result.new(
      allowed: true,
      reason_code: :product_enabled,
      product_key: product_key,
      details: details
    )

    product_key << "_changed"
    nested_value << "_changed"

    assert_equal "core", result.product_key
    assert_equal "private-copy", result.details.fetch(:nested).first
    assert_predicate result.product_key, :frozen?
    assert_predicate result.details.fetch(:nested), :frozen?
    assert_predicate result.details.fetch(:nested).first, :frozen?
  end

  private
    def policy(subscription, now: Time.current, past_due_grace_period: 15.days)
      Entitlements::SubscriptionAccessPolicy.new(
        subscription: subscription,
        now: now,
        past_due_grace_period: past_due_grace_period
      )
    end
end
