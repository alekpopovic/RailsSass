require "test_helper"
require_relative "../../../support/organization_test_helper"

class Organizations::Memberships::ReactivateTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "reactivate-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(owner: @owner)
    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
  end

  teardown do
    Current.reset
  end

  test "reactivation preserves role and joined at and creates the locator atomically" do
    user = create_test_user(email_address: "reactivate-member@example.test")
    joined_at = 2.months.ago
    membership = create_test_membership(
      organization: @organization,
      user: user,
      role: :member,
      status: :suspended,
      joined_at: joined_at
    )

    assert_difference -> { OrganizationAccessLocator.count }, 1 do
      membership = Organizations::Memberships::Reactivate.new(
        actor: @owner,
        membership_id: membership.id
      ).call

      assert_predicate membership, :active?
      assert_predicate membership, :member?
      assert_equal joined_at.change(usec: joined_at.usec), membership.joined_at
    end
  end

  test "admin can reactivate member and admin but not owner or billing" do
    admin = create_test_user(email_address: "reactivate-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    establish_tenant_context(user: admin, organization: @organization, membership: admin_membership)

    %i[member admin].each do |role|
      target_user = create_test_user(email_address: "reactivate-target-#{role}@example.test")
      target = create_test_membership(
        organization: @organization,
        user: target_user,
        role: role,
        status: :suspended
      )

      assert_predicate Organizations::Memberships::Reactivate.new(
        actor: admin,
        membership_id: target.id
      ).call, :active?
    end

    %i[owner billing].each do |role|
      target_user = create_test_user(email_address: "denied-reactivate-#{role}@example.test")
      target = create_test_membership(
        organization: @organization,
        user: target_user,
        role: role,
        status: :suspended
      )

      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::Memberships::Reactivate.new(
          actor: admin,
          membership_id: target.id
        ).call
      end
    end
  end
end
