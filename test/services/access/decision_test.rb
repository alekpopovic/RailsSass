require "test_helper"

class Access::DecisionTest < ActiveSupport::TestCase
  test "exposes a complete allowed finite-capacity decision" do
    decision = Access::Decision.new(
      allowed: true,
      reason_code: "access_granted",
      message: "Access is available.",
      plan_key: "professional",
      plan_source: "paid",
      product_key: "analytics",
      feature_key: "reports",
      feature_kind: "limit",
      limit_value: 10,
      unlimited: false,
      details: { subscription_reason_code: :subscription_active }
    )

    assert_equal true, decision.allowed
    assert_predicate decision, :allowed?
    assert_not_predicate decision, :denied?
    assert_equal :access_granted, decision.reason_code
    assert_equal "Access is available.", decision.message
    assert_equal "professional", decision.plan_key
    assert_equal :paid, decision.plan_source
    assert_equal "analytics", decision.product_key
    assert_equal "reports", decision.feature_key
    assert_equal :limit, decision.feature_kind
    assert_equal 10, decision.limit_value
    assert_equal false, decision.unlimited
    assert_not_predicate decision, :unlimited?
    assert_equal 10, decision.capacity
    assert_equal({ subscription_reason_code: :subscription_active }, decision.details)
    assert_predicate decision, :frozen?
  end

  test "returns unlimited or nil capacity with entitlement result semantics" do
    unlimited = Access::Decision.new(
      allowed: true,
      reason_code: :access_granted,
      feature_kind: :limit,
      unlimited: true
    )
    zero = Access::Decision.new(
      allowed: true,
      reason_code: :access_granted,
      feature_kind: :limit,
      limit_value: 0
    )
    flag = Access::Decision.new(
      allowed: true,
      reason_code: :access_granted,
      feature_kind: :flag,
      unlimited: true
    )
    denied = Access::Decision.new(
      allowed: false,
      reason_code: :permission_not_granted,
      feature_kind: :limit,
      limit_value: 10
    )

    assert_equal Entitlements::Result::UNLIMITED, unlimited.capacity
    assert_equal Access::Decision::UNLIMITED, unlimited.capacity
    assert_predicate unlimited, :unlimited?
    assert_equal 0, zero.capacity
    assert_nil flag.capacity
    assert_nil denied.capacity
  end

  test "accepts every declared denial reason code" do
    denial_codes = Access::Decision::OWN_REASON_CODES.without(:access_granted) +
      Access::Decision::ENTITLEMENT_DENIAL_REASON_CODES

    denial_codes.each do |reason_code|
      decision = Access::Decision.new(allowed: false, reason_code: reason_code)

      assert_predicate decision, :denied?, "expected #{reason_code} to deny"
      assert_equal reason_code, decision.reason_code
    end
  end

  test "rejects unknown and missing reason codes" do
    invalid_reason_codes = [
      :unknown,
      "unknown",
      :product_enabled,
      :feature_enabled,
      :subscription_active,
      nil,
      Object.new
    ]

    invalid_reason_codes.each do |reason_code|
      error = assert_raises(ArgumentError) do
        Access::Decision.new(allowed: false, reason_code: reason_code)
      end

      assert_equal "unknown access reason code", error.message
    end
  end

  test "requires boolean outcome and unlimited values" do
    [ nil, 0, "false" ].each do |invalid_allowed|
      assert_raises(ArgumentError) do
        Access::Decision.new(
          allowed: invalid_allowed,
          reason_code: :permission_not_granted
        )
      end
    end

    [ nil, 0, "false" ].each do |invalid_unlimited|
      assert_raises(ArgumentError) do
        Access::Decision.new(
          allowed: false,
          reason_code: :permission_not_granted,
          unlimited: invalid_unlimited
        )
      end
    end
  end

  test "requires access_granted if and only if the decision is allowed" do
    invalid_outcomes = [
      { allowed: false, reason_code: :access_granted },
      { allowed: true, reason_code: :permission_not_granted }
    ]

    invalid_outcomes.each do |attributes|
      error = assert_raises(ArgumentError) do
        Access::Decision.new(**attributes)
      end

      assert_equal "only access_granted may represent an allowed decision", error.message
    end
  end

  test "owns deeply immutable copies of caller metadata" do
    message = +"Access denied."
    plan_key = +"starter"
    product_key = +"analytics"
    feature_key = +"exports"
    detail_key = +"requirement"
    detail_value = +"upgrade"
    details = { detail_key => [ { value: detail_value } ] }
    decision = Access::Decision.new(
      allowed: false,
      reason_code: :feature_not_entitled,
      message: message,
      plan_key: plan_key,
      product_key: product_key,
      feature_key: feature_key,
      details: details
    )

    message << " changed"
    plan_key << "_changed"
    product_key << "_changed"
    feature_key << "_changed"
    detail_key << "_changed"
    detail_value << "_changed"

    assert_equal "Access denied.", decision.message
    assert_equal "starter", decision.plan_key
    assert_equal "analytics", decision.product_key
    assert_equal "exports", decision.feature_key
    assert_equal "upgrade", decision.details.fetch("requirement").first.fetch(:value)
    assert_predicate decision.message, :frozen?
    assert_predicate decision.plan_key, :frozen?
    assert_predicate decision.product_key, :frozen?
    assert_predicate decision.feature_key, :frozen?
    assert_predicate decision.details, :frozen?
    assert_predicate decision.details.keys.first, :frozen?
    assert_predicate decision.details.values.first, :frozen?
    assert_predicate decision.details.values.first.first, :frozen?
    assert_predicate decision.details.values.first.first.fetch(:value), :frozen?
  end
end
