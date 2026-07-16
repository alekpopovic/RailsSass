require "test_helper"
require_relative "../../support/product_rbac_test_helper"

class Access::PermissionCheckerTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  setup do
    @owner = create_test_user(email_address: "permission-checker-owner@example.test")
    @organization, @membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Permission Checker Organization",
      slug: "permission-checker-organization"
    )
    @product = create_test_product(key: "permission_checker_product")
    @permission = create_test_product_permission(
      product: @product,
      key: "reports.view"
    )
    Current.organization = @organization
  end

  teardown do
    Current.reset
  end

  test "distinguishes missing and suspended product memberships" do
    missing = check

    assert_predicate missing, :product_membership_missing?
    assert_not_predicate missing, :product_membership_suspended?
    assert_not_predicate missing, :permission_granted?
    assert_not_predicate missing, :allowed?
    assert_predicate missing, :frozen?

    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: @product
    )
    @organization.product_memberships.where(id: product_membership.id)
      .update_all(status: "suspended", updated_at: Time.current)

    suspended = check

    assert_equal "suspended", suspended.product_membership_status
    assert_not_predicate suspended, :product_membership_missing?
    assert_predicate suspended, :product_membership_suspended?
    assert_not_predicate suspended, :permission_granted?
    assert_not_predicate suspended, :allowed?
  end

  test "allows permission from an active system role" do
    grant_permission

    result = check

    assert_equal "active", result.product_membership_status
    assert_predicate result, :permission_granted?
    assert_predicate result, :allowed?
  end

  test "allows permission from an active role owned by the current organization" do
    grant_permission(organization: @organization)

    assert_predicate check, :allowed?
  end

  test "unions permissions from multiple active assigned roles" do
    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: @product
    )
    unprivileged_role = create_test_product_role(product: @product, key: "observer")
    privileged_role = create_test_product_role(product: @product, key: "report_viewer")
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: unprivileged_role
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: privileged_role
    )
    create_test_product_role_permission(
      product_role: privileged_role,
      product_permission: @permission
    )

    assert_predicate check, :allowed?
  end

  test "denies an active product membership without the requested permission" do
    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: @product
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: create_test_product_role(product: @product)
    )

    result = check

    assert_equal "active", result.product_membership_status
    assert_not_predicate result, :permission_granted?
    assert_not_predicate result, :allowed?
  end

  test "ignores a role that became inactive after assignment" do
    _product_membership, role = grant_permission
    role.update!(active: false)

    result = check

    assert_equal "active", result.product_membership_status
    assert_not_predicate result, :permission_granted?
    assert_not_predicate result, :allowed?
  end

  test "does not grant an identical permission key from another product" do
    create_test_product_membership(
      organization_membership: @membership,
      product: @product
    )
    other_product = create_test_product(key: "permission_checker_other_product")
    other_permission = create_test_product_permission(
      product: other_product,
      key: @permission.key
    )
    other_role = create_test_product_role(product: other_product)
    create_test_product_role_permission(
      product_role: other_role,
      product_permission: other_permission
    )

    result = check

    assert_equal "active", result.product_membership_status
    assert_not_predicate result, :permission_granted?
    assert_not_predicate result, :allowed?
  end

  test "does not filter an existing grant by the product active flag" do
    grant_permission
    @product.update!(active: false)

    assert_predicate check, :allowed?
  end

  test "fails closed for foreign tenant rows and mismatched current context" do
    foreign_owner = create_test_user(email_address: "permission-checker-foreign@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Permission Checker",
      slug: "foreign-permission-checker"
    )
    Current.organization = foreign_organization
    foreign_product_membership = create_test_product_membership(
      organization_membership: foreign_membership,
      product: @product
    )
    foreign_role = create_test_product_role(product: @product, key: "foreign_viewer")
    create_test_product_role_permission(
      product_role: foreign_role,
      product_permission: @permission
    )
    create_test_product_membership_role(
      product_membership: foreign_product_membership,
      product_role: foreign_role
    )

    Current.organization = @organization

    assert_predicate check, :product_membership_missing?
    assert_not_predicate check(
      organization: foreign_organization,
      membership: foreign_membership
    ), :allowed?
    assert_not_predicate check(membership: foreign_membership), :allowed?
  end

  test "fails closed for missing unpersisted suspended or inactive context" do
    grant_permission

    assert_not_predicate check(organization: nil), :allowed?
    assert_not_predicate check(
      membership: OrganizationMembership.new(
        organization_id: @organization.id,
        user_id: @owner.id,
        role: :owner,
        status: :active,
        joined_at: Time.current
      )
    ), :allowed?

    suspended_user = create_test_user(
      email_address: "permission-checker-suspended@example.test"
    )
    suspended_membership = create_test_membership(
      organization: @organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    assert_not_predicate check(membership: suspended_membership), :allowed?

    @organization.update!(status: :suspended)
    assert_not_predicate check, :allowed?

    @organization.update!(status: :active)
    Current.organization = nil
    assert_not_predicate check, :allowed?
  end

  private
    def check(
      organization: @organization,
      membership: @membership,
      product_key: @product.key,
      permission_key: @permission.key
    )
      Access::PermissionChecker.new(
        organization: organization,
        membership: membership,
        product_key: product_key,
        permission_key: permission_key
      ).call
    end

    def grant_permission(organization: nil)
      product_membership = create_test_product_membership(
        organization_membership: @membership,
        product: @product
      )
      role = create_test_product_role(
        product: @product,
        organization: organization
      )
      create_test_product_role_permission(
        product_role: role,
        product_permission: @permission
      )
      create_test_product_membership_role(
        product_membership: product_membership,
        product_role: role
      )

      [ product_membership, role ]
    end
end
