require "test_helper"
require_relative "../support/catalog_test_helper"

class PlanFeatureEntitlementTest < ActiveSupport::TestCase
  include CatalogTestHelper

  setup do
    @product = create_test_product
    @plan_product = create_test_plan_product(plan: create_test_plan, product: @product)
  end

  test "flag feature uses enabled without numeric values" do
    feature = create_test_product_feature(product: @product, kind: :flag)
    entitlement = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: false,
      settings: { "label" => "synthetic" }
    )

    assert_predicate entitlement, :flag?
    assert_not entitlement.enabled?
    assert_nil entitlement.limit_value
    assert_not entitlement.unlimited?
    assert_equal @product.id, entitlement.product_id
    assert_equal({ "label" => "synthetic" }, entitlement.settings)
  end

  test "flag feature rejects finite and unlimited values" do
    feature = create_test_product_feature(product: @product, kind: :flag)

    finite = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      limit_value: 1
    )
    unlimited = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      unlimited: true
    )

    assert_not finite.valid?
    assert_includes finite.errors[:limit_value], "must be blank for a flag feature"
    assert_not unlimited.valid?
    assert_includes unlimited.errors[:unlimited], "must be false for a flag feature"
  end

  test "limit feature accepts exactly one finite or unlimited capacity" do
    finite_feature = create_test_product_feature(product: @product, kind: :limit)
    unlimited_feature = create_test_product_feature(product: @product, kind: :limit)
    finite = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: finite_feature,
      enabled: false,
      limit_value: 0
    )
    unlimited = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: unlimited_feature,
      limit_value: nil,
      unlimited: true
    )

    assert_equal 0, finite.limit_value
    assert_not finite.enabled?
    assert_not finite.unlimited?
    assert_nil unlimited.limit_value
    assert_predicate unlimited, :unlimited?
  end

  test "limit feature rejects missing, negative, and conflicting capacities" do
    feature = create_test_product_feature(product: @product, kind: :limit)
    missing = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true
    )
    negative = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      limit_value: -1
    )
    conflicting = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      limit_value: 10,
      unlimited: true
    )

    assert_not missing.valid?
    assert_not negative.valid?
    assert_not conflicting.valid?
    assert_includes conflicting.errors[:limit_value], "must be blank when unlimited"
  end

  test "feature must belong to the same product as plan product" do
    other_feature = create_test_product_feature(product: create_test_product, kind: :flag)
    entitlement = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: other_feature,
      enabled: true
    )

    assert_not entitlement.valid?
    assert_includes entitlement.errors[:product_feature], "must belong to the plan product"
  end

  test "settings must be a JSON object" do
    feature = create_test_product_feature(product: @product, kind: :flag)
    entitlement = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      settings: [ "not", "an", "object" ]
    )

    assert_not entitlement.valid?
    assert_includes entitlement.errors[:settings], "must be an object"
  end
end
