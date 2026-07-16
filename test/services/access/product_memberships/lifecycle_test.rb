require "test_helper"
require_relative "support"

class Access::ProductMemberships::LifecycleTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport

  setup do
    create_access_test_records
  end

  teardown do
    Current.reset
  end

  test "add creates one active product membership and is idempotent" do
    first = nil

    assert_difference -> { @organization.product_memberships.count }, 1 do
      first = add_product_membership
    end

    assert_predicate first, :active?
    assert_equal @organization.id, first.organization_id
    assert_equal @organization_membership.id, first.organization_membership_id
    assert_equal @product.id, first.product_id

    assert_no_difference -> { @organization.product_memberships.count } do
      second = add_product_membership
      assert_equal first.id, second.id
    end
  end

  test "add requires an active organization membership and active product" do
    suspended_user = create_test_user(email_address: "suspended-product-member@example.test")
    suspended_membership = create_test_membership(
      organization: @organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )

    assert_no_difference -> { @organization.product_memberships.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        add_product_membership(organization_membership: suspended_membership)
      end
    end

    @product.update!(active: false)

    assert_no_difference -> { @organization.product_memberships.count } do
      assert_raises(ActiveRecord::RecordNotFound) { add_product_membership }
    end
  end

  test "add does not reactivate a suspended product membership" do
    product_membership = add_product_membership
    Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id
    ).call

    assert_raises(ActiveRecord::RecordInvalid) { add_product_membership }
    assert_predicate product_membership.reload, :suspended?
  end

  test "suspend and reactivate are idempotent and preserve role assignments" do
    product_membership = add_product_membership
    product_role = create_access_test_role
    assignment = assign_product_role(
      product_membership: product_membership,
      product_role: product_role
    )

    suspended = Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id
    ).call
    suspended_again = Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id
    ).call

    assert_predicate suspended, :suspended?
    assert_equal suspended.id, suspended_again.id
    assert ProductMembershipRole.exists?(assignment.id)

    reactivated = Access::ProductMemberships::Reactivate.new(
      product_membership_id: product_membership.id
    ).call
    reactivated_again = Access::ProductMemberships::Reactivate.new(
      product_membership_id: product_membership.id
    ).call

    assert_predicate reactivated, :active?
    assert_equal reactivated.id, reactivated_again.id
    assert ProductMembershipRole.exists?(assignment.id)
  end

  test "reactivate fails closed when the product is inactive" do
    product_membership = add_product_membership
    Access::ProductMemberships::Suspend.new(
      product_membership_id: product_membership.id
    ).call
    @product.update!(active: false)

    assert_raises(ActiveRecord::RecordNotFound) do
      Access::ProductMemberships::Reactivate.new(
        product_membership_id: product_membership.id
      ).call
    end

    assert_predicate product_membership.reload, :suspended?
  end

  test "remove deletes the product membership and its role assignments" do
    product_membership = add_product_membership
    assignment = assign_product_role(
      product_membership: product_membership,
      product_role: create_access_test_role
    )

    removed = nil
    assert_difference -> { ProductMembership.count }, -1 do
      assert_difference -> { ProductMembershipRole.count }, -1 do
        removed = Access::ProductMemberships::Remove.new(
          product_membership_id: product_membership.id
        ).call
      end
    end

    assert_predicate removed, :destroyed?
    assert_not ProductMembershipRole.exists?(assignment.id)
    assert_raises(ActiveRecord::RecordNotFound) do
      Access::ProductMemberships::Remove.new(
        product_membership_id: product_membership.id
      ).call
    end
  end

  test "every operation requires a persisted active Current organization" do
    Current.reset

    assert_raises(ActiveRecord::RecordNotFound) { add_product_membership }

    Current.organization = @organization
    @organization.update!(status: :suspended)

    assert_raises(ActiveRecord::RecordNotFound) { add_product_membership }
  end
end
