require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductMembershipRoleTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  setup do
    @owner = create_test_user(email_address: "membership-role-owner@example.test")
    @organization, @organization_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Membership Role Organization",
      slug: "membership-role-organization"
    )
    @product = create_test_product
    @product_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: @product
    )
  end

  test "accepts system and same-organization roles and rejects duplicates" do
    system_role = create_test_product_role(product: @product)
    custom_role = create_test_product_role(
      product: @product,
      organization: @organization
    )
    first = create_test_product_membership_role(
      product_membership: @product_membership,
      product_role: system_role
    )
    second = create_test_product_membership_role(
      product_membership: @product_membership,
      product_role: custom_role
    )

    assert_equal @organization.id, first.organization_id
    assert_equal @product.id, first.product_id
    assert_predicate second, :persisted?

    duplicate = ProductMembershipRole.new(
      product_membership: @product_membership,
      product_role: system_role
    )
    assert_not duplicate.valid?
  end

  test "rejects foreign-organization cross-product inactive and suspended assignments" do
    foreign_owner = create_test_user(email_address: "foreign-membership-role-owner@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Membership Role",
      slug: "foreign-membership-role"
    )
    foreign_role = create_test_product_role(
      product: @product,
      organization: foreign_organization
    )
    foreign_assignment = ProductMembershipRole.new(
      product_membership: @product_membership,
      product_role: foreign_role
    )
    assert_not foreign_assignment.valid?

    cross_product = ProductMembershipRole.new(
      product_membership: @product_membership,
      product_role: create_test_product_role(product: create_test_product)
    )
    assert_not cross_product.valid?

    inactive_assignment = ProductMembershipRole.new(
      product_membership: @product_membership,
      product_role: create_test_product_role(product: @product, active: false)
    )
    assert_not inactive_assignment.valid?

    @organization.product_memberships.where(id: @product_membership.id)
      .update_all(status: "suspended", updated_at: Time.current)
    suspended_assignment = ProductMembershipRole.new(
      product_membership: @product_membership.reload,
      product_role: create_test_product_role(product: @product)
    )
    assert_not suspended_assignment.valid?
  end
end
