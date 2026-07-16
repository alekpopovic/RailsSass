require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductPermissionTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  test "normalizes stable keys and display metadata" do
    permission = create_test_product_permission(
      product: create_test_product,
      key: " Reports.Export ",
      name: " Export reports ",
      description: " Export reviewed reports. "
    )

    assert_equal "reports.export", permission.key
    assert_equal "Export reports", permission.name
    assert_equal "Export reviewed reports.", permission.description
  end

  test "requires a dot-separated unique key within the product" do
    product = create_test_product
    create_test_product_permission(product: product, key: "reports.view")
    duplicate = ProductPermission.new(
      product: product,
      key: "reports.view",
      name: "Duplicate",
      description: ""
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
    %w[reports_view reports_.view reports__draft.view reports.view_].each do |key|
      invalid_key = ProductPermission.new(
        product: product,
        key: key,
        name: "Invalid",
        description: ""
      )

      assert_not invalid_key.valid?, "expected #{key.inspect} to be invalid"
      assert_predicate invalid_key.errors[:key], :present?
    end
    assert create_test_product_permission(
      product: create_test_product,
      key: "reports.view"
    ).persisted?
  end
end
