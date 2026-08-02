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

  test "settings accept bounded nested non-sensitive catalog configuration" do
    feature = create_test_product_feature(product: @product, kind: :flag)
    entitlement = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      settings: {
        "display" => { "label" => "Synthetic feature" },
        "rules" => [ { "threshold" => 10, "token_bucket_size" => 100 } ],
        "operator_note" => "x" * 20_000
      }
    )

    assert_predicate entitlement, :valid?
  end

  test "settings reject oversized and deeply nested configuration" do
    feature = create_test_product_feature(product: @product, kind: :flag)
    oversized = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      settings: { "label" => "x" * 65_536 }
    )
    deeply_nested = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      settings: 21.times.reduce({ "label" => "bounded" }) { |value, _index| { "nested" => value } }
    )

    assert_not oversized.valid?
    assert_includes oversized.errors[:settings], "must be at most 64 KiB"
    assert_not deeply_nested.valid?
    assert_includes deeply_nested.errors[:settings], "must be at most 20 levels deep"
  end

  test "settings reject recursively nested sensitive fields" do
    feature = create_test_product_feature(product: @product, kind: :flag)

    sensitive_keys = [
      "apiKey",
      "access-token",
      "customer_email",
      "password_hash",
      "private_key_encrypted",
      "api.key",
      "access/key",
      "password value",
      "private.key.encrypted"
    ]
    sensitive_keys.each do |sensitive_key|
      entitlement = PlanFeatureEntitlement.new(
        plan_product: @plan_product,
        product_feature: feature,
        enabled: true,
        settings: { "rules" => [ { sensitive_key => "private-value" } ] }
      )

      assert_not entitlement.valid?, "expected #{sensitive_key} to be rejected"
      assert_includes entitlement.errors[:settings], "contains a sensitive field"
    end
  end

  test "settings use PostgreSQL JSONB storage size rather than JSON text size alone" do
    feature = create_test_product_feature(product: @product, kind: :flag)
    settings = 4_800.times.to_h { |index| [ "k#{index}", "x" ] }
    serialized_settings = JSON.generate(settings)
    entitlement = PlanFeatureEntitlement.new(
      plan_product: @plan_product,
      product_feature: feature,
      enabled: true,
      settings: settings
    )

    assert_operator serialized_settings.bytesize, :<, PlanFeatureEntitlement::SETTINGS_MAX_BYTES
    assert_operator entitlement.send(:jsonb_storage_bytes, serialized_settings),
      :>,
      PlanFeatureEntitlement::SETTINGS_MAX_BYTES
    assert_not entitlement.valid?
    assert_includes entitlement.errors[:settings], "must be at most 64 KiB"
  end
end
