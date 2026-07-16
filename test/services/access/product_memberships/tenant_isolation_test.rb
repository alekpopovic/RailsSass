require "test_helper"
require_relative "support"

class Access::ProductMemberships::TenantIsolationTest < ActiveSupport::TestCase
  include AccessProductMembershipsTestSupport

  setup do
    create_access_test_records
  end

  teardown do
    Current.reset
  end

  test "foreign organization membership and product membership IDs behave as not found" do
    foreign_owner = create_test_user(email_address: "foreign-product-owner@example.test")
    foreign_organization, foreign_owner_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Product Organization",
      slug: "foreign-product-organization"
    )
    foreign_member = create_test_user(email_address: "foreign-product-member@example.test")
    foreign_organization_membership = create_test_membership(
      organization: foreign_organization,
      user: foreign_member,
      role: :member
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      Access::ProductMemberships::Add.new(
        organization_membership_id: foreign_organization_membership.id,
        product_id: @product.id
      ).call
    end

    Current.organization = foreign_organization
    foreign_product_membership = Access::ProductMemberships::Add.new(
      organization_membership_id: foreign_organization_membership.id,
      product_id: @product.id
    ).call
    Current.organization = @organization

    %w[Remove Suspend Reactivate].each do |operation_name|
      operation = Access::ProductMemberships.const_get(operation_name)

      assert_raises(ActiveRecord::RecordNotFound) do
        operation.new(product_membership_id: foreign_product_membership.id).call
      end
    end

    system_role = create_access_test_role
    assert_raises(ActiveRecord::RecordNotFound) do
      Access::ProductMemberships::AssignRole.new(
        product_membership_id: foreign_product_membership.id,
        product_role_id: system_role.id
      ).call
    end

    assert_predicate foreign_product_membership.reload, :active?
    assert_equal foreign_owner_membership.organization_id, foreign_organization.id
  end
end
