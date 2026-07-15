module CatalogTestHelper
  def unique_catalog_key(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}"
  end

  def create_test_product(**overrides)
    Product.create!({
      key: unique_catalog_key("product"),
      name: "Test Product",
      description: "Synthetic product for catalog tests.",
      active: true
    }.merge(overrides))
  end

  def create_test_product_feature(product:, **overrides)
    ProductFeature.create!({
      product: product,
      key: unique_catalog_key("feature"),
      name: "Test Feature",
      description: "Synthetic feature for catalog tests.",
      kind: :flag,
      active: true
    }.merge(overrides))
  end

  def create_test_plan(**overrides)
    Plan.create!({
      key: unique_catalog_key("plan"),
      name: "Test Plan",
      description: "Synthetic plan for catalog tests.",
      active: true,
      free: false,
      position: 0
    }.merge(overrides))
  end

  def create_test_plan_product(plan:, product:)
    PlanProduct.create!(plan: plan, product: product)
  end

  def create_test_entitlement(plan_product:, product_feature:, **overrides)
    defaults = {
      plan_product: plan_product,
      product_feature: product_feature,
      enabled: true,
      unlimited: false,
      settings: {}
    }
    defaults[:limit_value] = 10 if product_feature.kind == "limit"

    PlanFeatureEntitlement.create!(defaults.merge(overrides))
  end

  def create_test_plan_price(plan:, **overrides)
    PlanPrice.create!({
      plan: plan,
      billing_interval: :monthly,
      currency: "EUR",
      amount_cents: 1_000,
      active: true
    }.merge(overrides))
  end
end
