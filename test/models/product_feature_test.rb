require "test_helper"
require_relative "../support/catalog_test_helper"

class ProductFeatureTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "feature keys are unique only inside their product" do
    first_product = create_test_product
    second_product = create_test_product
    create_test_product_feature(product: first_product, key: "exports")

    duplicate = ProductFeature.new(
      product: first_product,
      key: "EXPORTS",
      name: "Duplicate",
      kind: :flag
    )
    other_product_feature = ProductFeature.new(
      product: second_product,
      key: "exports",
      name: "Other product feature",
      kind: :limit
    )

    assert_not duplicate.valid?
    assert_predicate other_product_feature, :valid?
  end

  test "exposes flag and limit kinds without changing stable identity" do
    product = create_test_product
    feature = create_test_product_feature(product: product, kind: :limit)

    assert_predicate feature, :limit?
    assert_raises(ActiveRecord::ReadonlyAttributeError) { feature.update!(kind: :flag) }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { feature.update!(product: create_test_product) }
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      feature.update!(key: unique_catalog_key("changed_feature"))
    end
  end
end
