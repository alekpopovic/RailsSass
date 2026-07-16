require "test_helper"
require_relative "support"

class Access::ProductMemberships::AssignRoleTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport

  setup do
    create_access_test_records
    @product_membership = add_product_membership
  end

  teardown do
    Current.reset
  end

  test "assigns system and current organization roles and is idempotent" do
    system_role = create_access_test_role
    organization_role = create_access_test_role(
      organization: @organization,
      key: "organization_viewer"
    )

    first_assignment = assign_product_role(
      product_membership: @product_membership,
      product_role: system_role
    )

    assert_no_difference -> { ProductMembershipRole.count } do
      repeated_assignment = assign_product_role(
        product_membership: @product_membership,
        product_role: system_role
      )
      assert_equal first_assignment.id, repeated_assignment.id
    end

    organization_assignment = assign_product_role(
      product_membership: @product_membership,
      product_role: organization_role
    )

    assert_equal @organization.id, first_assignment.organization_id
    assert_equal @product.id, first_assignment.product_id
    assert_equal organization_role.id, organization_assignment.product_role_id
    assert_equal 2, @product_membership.product_membership_roles.count
  end

  test "rejects inactive suspended and cross-product inputs" do
    inactive_role = create_access_test_role(key: "inactive_role", active: false)

    assert_raises(ActiveRecord::RecordNotFound) do
      assign_product_role(
        product_membership: @product_membership,
        product_role: inactive_role
      )
    end

    other_product = create_access_test_product(key: "other_product_#{SecureRandom.hex(4)}")
    other_product_role = create_access_test_role(
      product: other_product,
      key: "other_viewer"
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      assign_product_role(
        product_membership: @product_membership,
        product_role: other_product_role
      )
    end

    Access::ProductMemberships::Suspend.new(
      product_membership_id: @product_membership.id
    ).call

    assert_raises(ActiveRecord::RecordInvalid) do
      assign_product_role(
        product_membership: @product_membership,
        product_role: create_access_test_role(key: "suspended_viewer")
      )
    end

    assert_empty @product_membership.product_membership_roles
  end

  test "rejects a new role assignment when the product has been deactivated" do
    role = create_access_test_role
    @product.update!(active: false)

    assert_raises(ActiveRecord::RecordNotFound) do
      assign_product_role(
        product_membership: @product_membership,
        product_role: role
      )
    end

    assert_empty @product_membership.product_membership_roles
  end

  test "rejects an organization role owned by another tenant" do
    other_owner = create_test_user(email_address: "other-role-owner@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Product Role Organization",
      slug: "other-product-role-organization"
    )
    foreign_role = create_access_test_role(
      organization: other_organization,
      key: "foreign_viewer"
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      assign_product_role(
        product_membership: @product_membership,
        product_role: foreign_role
      )
    end

    assert_empty @product_membership.product_membership_roles
  end
end
