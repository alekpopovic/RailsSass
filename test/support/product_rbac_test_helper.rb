require_relative "catalog_test_helper"
require_relative "organization_test_helper"

module ProductRbacTestHelper
  include CatalogTestHelper
  include OrganizationTestHelper

  def create_test_product_permission(product:, **overrides)
    ProductPermission.create!({
      product: product,
      key: "resource_#{SecureRandom.hex(4)}.view",
      name: "View resource",
      description: "Synthetic product permission."
    }.merge(overrides))
  end

  def create_test_product_role(product:, organization: nil, **overrides)
    ProductRole.create!({
      product: product,
      organization: organization,
      key: unique_catalog_key("role"),
      name: "Test Role",
      system: organization.nil?,
      active: true
    }.merge(overrides))
  end

  def create_test_product_role_permission(product_role:, product_permission:, **overrides)
    ProductRolePermission.create!({
      product_role: product_role,
      product_permission: product_permission
    }.merge(overrides))
  end

  def create_test_product_membership(organization_membership:, product:, **overrides)
    ProductMembership.create!({
      organization_membership: organization_membership,
      product: product,
      status: :active
    }.merge(overrides))
  end

  def create_test_product_membership_role(product_membership:, product_role:, **overrides)
    ProductMembershipRole.create!({
      product_membership: product_membership,
      product_role: product_role
    }.merge(overrides))
  end
end
