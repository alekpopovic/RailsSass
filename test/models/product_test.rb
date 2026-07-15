require "test_helper"
require_relative "../support/catalog_test_helper"

class ProductTest < ActiveSupport::TestCase
  include CatalogTestHelper

  test "normalizes stable key and display attributes" do
    product = Product.create!(
      key: "  CUSTOMER_PORTAL  ",
      name: "  Customer Portal  ",
      description: "  Shared customer workspace.  "
    )

    assert_equal "customer_portal", product.key
    assert_equal "Customer Portal", product.name
    assert_equal "Shared customer workspace.", product.description
    assert_predicate product, :active?
  end

  test "validates stable key format and uniqueness" do
    product = create_test_product(key: "stable_product")
    duplicate = Product.new(key: "STABLE_PRODUCT", name: "Duplicate")
    malformed = Product.new(key: "not-a-key", name: "Malformed")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
    assert_not malformed.valid?
    assert_includes malformed.errors[:key], "is invalid"
    assert_equal product, Product.find_by!(key: "stable_product")
  end

  test "stable key is readonly after creation" do
    product = create_test_product

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      product.update!(key: unique_catalog_key("changed"))
    end
  end
end
