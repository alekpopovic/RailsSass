require "test_helper"
require_relative "../support/catalog_test_helper"

class PlanPriceTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "normalizes currency and complete opaque Lemon identifiers" do
    price = create_test_plan_price(
      plan: create_test_plan,
      billing_interval: :yearly,
      currency: " eur ",
      lemon_store_id: " store-1 ",
      lemon_product_id: " product-1 ",
      lemon_variant_id: " variant-1 "
    )

    assert_predicate price, :yearly?
    assert_equal "EUR", price.currency
    assert_equal "store-1", price.lemon_store_id
    assert_equal "product-1", price.lemon_product_id
    assert_equal "variant-1", price.lemon_variant_id
  end

  test "validates interval currency amount and complete Lemon mapping" do
    plan = create_test_plan
    invalid = PlanPrice.new(
      plan: plan,
      billing_interval: :weekly,
      currency: "EURO",
      amount_cents: -1,
      lemon_variant_id: "variant-only"
    )

    assert_not invalid.valid?
    assert_includes invalid.errors[:billing_interval], "is not included in the list"
    assert_includes invalid.errors[:currency], "is the wrong length (should be 3 characters)"
    assert_includes invalid.errors[:amount_cents], "must be greater than or equal to 0"
    assert_includes invalid.errors[:lemon_variant_id], "must be provided with store and product IDs"
  end

  test "rejects whitespace inside opaque Lemon identifiers" do
    price = PlanPrice.new(
      plan: create_test_plan,
      billing_interval: :monthly,
      currency: "EUR",
      amount_cents: 1_000,
      lemon_store_id: "store 1",
      lemon_product_id: "product-1",
      lemon_variant_id: "variant-1"
    )

    assert_not price.valid?
    assert_includes price.errors[:lemon_store_id], "is invalid"
  end

  test "Lemon variant identity is globally unique when present" do
    create_test_plan_price(
      plan: create_test_plan,
      lemon_store_id: "store-a",
      lemon_product_id: "product-a",
      lemon_variant_id: "variant-stable"
    )
    duplicate = build_price_with_mapping(create_test_plan, "variant-stable")
    unmapped = create_test_plan_price(plan: create_test_plan)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:lemon_variant_id], "has already been taken"
    assert_nil unmapped.lemon_variant_id
  end

  test "plan identity cannot be repointed after price creation" do
    price = create_test_plan_price(plan: create_test_plan)
    other_plan = create_test_plan

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      price.update!(plan: other_plan)
    end

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        PlanPrice.where(id: price.id).update_all(plan_id: other_plan.id)
      end
    end
    assert_kind_of PG::CheckViolation, error.cause
  end

  private
    def build_price_with_mapping(plan, variant_id)
      PlanPrice.new(
        plan: plan,
        billing_interval: :monthly,
        currency: "USD",
        amount_cents: 1_000,
        lemon_store_id: "store-b",
        lemon_product_id: "product-b",
        lemon_variant_id: variant_id
      )
    end
end
