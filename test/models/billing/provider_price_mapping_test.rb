require "test_helper"
require_relative "../../support/billing_test_helper"

class Billing::ProviderPriceMappingTest < ActiveSupport::TestCase
  include BillingTestHelper

  test "binds one environment-qualified provider identity to an exact plan price" do
    price = mapped_price
    mapping = create_billing_provider_price_mapping(plan_price: price, environment: "test")

    assert_predicate mapping, :environment_test?
    assert_predicate mapping, :test_mode?
    assert_predicate mapping, :checkout_eligible?
    assert_equal price.lemon_store_id, mapping.provider_store_id
    assert_equal price.lemon_product_id, mapping.provider_product_id
    assert_equal price.lemon_variant_id, mapping.provider_variant_id
  end

  test "rejects provider identifiers that do not match the plan price" do
    price = mapped_price
    mapping = price.billing_provider_price_mappings.new(
      provider: "lemon_squeezy",
      environment: "test",
      provider_store_id: price.lemon_store_id,
      provider_product_id: price.lemon_product_id,
      provider_variant_id: "999999",
      active: true
    )

    assert_not mapping.valid?
    assert_includes mapping.errors[:plan_price], "must have the same Lemon provider identifiers"
  end

  test "mapping identity is immutable while active can be deactivated" do
    mapping = create_billing_provider_price_mapping(plan_price: mapped_price)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      mapping.update!(environment: "live")
    end
    mapping.update!(active: false)

    assert_not mapping.active?
  end

  private
    def mapped_price
      create_test_plan_price(
        plan: create_test_plan,
        lemon_store_id: "510001",
        lemon_product_id: "520002",
        lemon_variant_id: "530003"
      )
    end
end
