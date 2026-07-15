require "test_helper"
require_relative "../support/catalog_test_helper"

class PlanProductTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "a plan contains a product at most once" do
    plan = create_test_plan
    product = create_test_product
    plan_product = create_test_plan_product(plan: plan, product: product)
    duplicate = PlanProduct.new(plan: plan, product: product)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:product_id], "has already been taken"
    assert_includes plan.products, product
    assert_includes product.plans, plan
    assert_equal plan_product, plan.reload.plan_products.sole
  end

  test "plan and product identity are readonly" do
    plan_product = create_test_plan_product(plan: create_test_plan, product: create_test_product)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      plan_product.update!(product: create_test_product)
    end
  end
end
