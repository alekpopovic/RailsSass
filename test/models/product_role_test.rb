require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductRoleTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  test "supports system and organization scopes with independent key uniqueness" do
    product = create_test_product
    first_owner = create_test_user(email_address: "role-first-owner@example.test")
    second_owner = create_test_user(email_address: "role-second-owner@example.test")
    first_organization, = create_test_organization_with_owner(
      owner: first_owner,
      name: "First Role Organization",
      slug: "first-role-organization"
    )
    second_organization, = create_test_organization_with_owner(
      owner: second_owner,
      name: "Second Role Organization",
      slug: "second-role-organization"
    )
    system_role = create_test_product_role(product: product, key: "viewer")
    first_custom = create_test_product_role(
      product: product,
      organization: first_organization,
      key: "viewer"
    )
    second_custom = create_test_product_role(
      product: product,
      organization: second_organization,
      key: "viewer"
    )

    assert_predicate system_role, :system?
    assert_nil system_role.organization_id
    assert_not first_custom.system?
    assert_equal first_organization.id, first_custom.organization_id
    assert_predicate second_custom, :persisted?

    duplicate_system = ProductRole.new(
      product: product,
      key: "viewer",
      name: "Duplicate Viewer",
      system: true,
      active: true
    )
    assert_not duplicate_system.valid?
    assert_includes duplicate_system.errors[:key], "has already been taken"
  end

  test "requires system flag and organization ownership to agree" do
    product = create_test_product
    owner = create_test_user(email_address: "role-scope-owner@example.test")
    organization, = create_test_organization_with_owner(
      owner: owner,
      name: "Role Scope Organization",
      slug: "role-scope-organization"
    )

    global_custom = ProductRole.new(
      product: product,
      key: "global_custom",
      name: "Global Custom",
      system: false,
      active: true
    )
    tenant_system = ProductRole.new(
      product: product,
      organization: organization,
      key: "tenant_system",
      name: "Tenant System",
      system: true,
      active: true
    )

    assert_not global_custom.valid?
    assert_not tenant_system.valid?
  end

  test "identity is readonly while display and active state remain mutable" do
    role = create_test_product_role(product: create_test_product)

    assert_raises(ActiveRecord::ReadonlyAttributeError) { role.update!(key: "changed") }

    role.update!(name: "Renamed Role", active: false)
    assert_equal [ "Renamed Role", false ], role.reload.values_at(:name, :active)
  end
end
