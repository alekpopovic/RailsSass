require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductRolePermissionTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  test "derives product and rejects duplicates and cross-product grants" do
    product = create_test_product
    role = create_test_product_role(product: product)
    permission = create_test_product_permission(product: product)
    mapping = create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )

    assert_equal product.id, mapping.product_id

    duplicate = ProductRolePermission.new(
      product_role: role,
      product_permission: permission
    )
    assert_not duplicate.valid?

    foreign_permission = create_test_product_permission(product: create_test_product)
    mismatch = ProductRolePermission.new(
      product_role: role,
      product_permission: foreign_permission
    )
    assert_not mismatch.valid?
    assert_includes mismatch.errors[:product], "must match the role and permission product"
  end

  test "inactive roles cannot receive new permission mappings" do
    product = create_test_product
    role = create_test_product_role(product: product, active: false)
    mapping = ProductRolePermission.new(
      product_role: role,
      product_permission: create_test_product_permission(product: product)
    )

    assert_not mapping.valid?
    assert_includes mapping.errors[:product_role], "must be active for a new permission mapping"
  end
end
