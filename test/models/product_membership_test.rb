require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductMembershipTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  test "derives tenant ownership and supports active and suspended states" do
    owner = create_test_user(email_address: "product-member-owner@example.test")
    organization, owner_membership = create_test_organization_with_owner(
      owner: owner,
      name: "Product Member Organization",
      slug: "product-member-organization"
    )
    membership = create_test_product_membership(
      organization_membership: owner_membership,
      product: create_test_product
    )

    assert_equal organization.id, membership.organization_id
    assert_equal "active", membership.organization_membership_status
    assert_predicate membership, :active?

    membership = ProductMembership.find(membership.id)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      membership.update!(status: :suspended)
    end
  end

  test "rejects duplicate products suspended parents and inactive products" do
    owner = create_test_user(email_address: "product-member-rules-owner@example.test")
    organization, = create_test_organization_with_owner(
      owner: owner,
      name: "Product Membership Rules",
      slug: "product-membership-rules"
    )
    member = create_test_user(email_address: "product-member-rules-member@example.test")
    active_parent = create_test_membership(
      organization: organization,
      user: member,
      role: :member
    )
    product = create_test_product
    create_test_product_membership(
      organization_membership: active_parent,
      product: product
    )

    duplicate = ProductMembership.new(
      organization_membership: active_parent,
      product: product
    )
    assert_not duplicate.valid?

    suspended_user = create_test_user(email_address: "suspended-parent@example.test")
    suspended_parent = create_test_membership(
      organization: organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    suspended_assignment = ProductMembership.new(
      organization_membership: suspended_parent,
      product: create_test_product
    )
    assert_not suspended_assignment.valid?
    assert_includes suspended_assignment.errors[:organization_membership], "must be active"

    inactive_assignment = ProductMembership.new(
      organization_membership: active_parent,
      product: create_test_product(active: false)
    )
    assert_not inactive_assignment.valid?
    assert_includes inactive_assignment.errors[:product], "must be active for a new membership"
  end
end
