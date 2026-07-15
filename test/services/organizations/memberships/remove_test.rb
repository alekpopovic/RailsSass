require "test_helper"
require_relative "../../../support/organization_test_helper"

class Organizations::Memberships::RemoveTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "remove-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner
    )
  end

  teardown do
    Current.reset
  end

  test "remove suspends the membership without deleting its history" do
    member = create_test_user(email_address: "removed-member@example.test")
    membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member,
      joined_at: 2.days.ago
    )
    joined_at = membership.joined_at
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    assert_no_difference -> { OrganizationMembership.count } do
      membership = Organizations::Memberships::Remove.new(
        actor: @owner,
        membership_id: membership.id
      ).call

      assert_predicate membership, :suspended?
      assert_equal joined_at, membership.joined_at
    end
  end

  test "last active owner cannot leave or be suspended" do
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Organizations::Memberships::Remove.new(
        actor: @owner,
        membership_id: @owner_membership.id
      ).call
    end

    assert_includes error.record.errors[:base], OrganizationMembership::LAST_ACTIVE_OWNER_MESSAGE
    assert_predicate @owner_membership.reload, :active?
  end

  test "one owner may leave when another active owner remains" do
    second_owner = create_test_user(email_address: "remaining-owner@example.test")
    second_membership = create_test_membership(
      organization: @organization,
      user: second_owner,
      role: :owner
    )
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    removed = Organizations::Memberships::Remove.new(
      actor: @owner,
      membership_id: @owner_membership.id
    ).call

    assert_predicate removed, :suspended?
    assert_equal removed, Current.organization_membership
    assert_predicate second_membership.reload, :active?
    assert_equal 1, @organization.organization_memberships.active_owners.count
  end

  test "admin can remove member or admin but cannot remove owner or billing" do
    admin = create_test_user(email_address: "remove-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    member = create_test_user(email_address: "remove-member@example.test")
    member_membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member
    )
    managed_admin = create_test_user(email_address: "managed-admin@example.test")
    managed_admin_membership = create_test_membership(
      organization: @organization,
      user: managed_admin,
      role: :admin
    )
    billing = create_test_user(email_address: "remove-billing@example.test")
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing,
      role: :billing
    )
    establish_tenant_context(user: admin, organization: @organization, membership: admin_membership)

    removed_member = Organizations::Memberships::Remove.new(
      actor: admin,
      membership_id: member_membership.id
    ).call

    assert_predicate removed_member, :suspended?
    removed_admin = Organizations::Memberships::Remove.new(
      actor: admin,
      membership_id: managed_admin_membership.id
    ).call

    assert_predicate removed_admin, :suspended?
    assert_raises(Pundit::NotAuthorizedError) do
      Organizations::Memberships::Remove.new(
        actor: admin,
        membership_id: @owner_membership.id
      ).call
    end
    assert_raises(Pundit::NotAuthorizedError) do
      Organizations::Memberships::Remove.new(
        actor: admin,
        membership_id: billing_membership.id
      ).call
    end
  end

  test "billing and member roles cannot remove a member" do
    member = create_test_user(email_address: "billing-target@example.test")
    member_membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member
    )
    %i[billing member].each do |role|
      actor = create_test_user(email_address: "#{role}-remover@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      establish_tenant_context(
        user: actor,
        organization: @organization,
        membership: actor_membership
      )

      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::Memberships::Remove.new(
          actor: actor,
          membership_id: member_membership.id
        ).call
      end
    end

    assert_predicate member_membership.reload, :active?
  end

  test "target membership is always resolved through Current organization" do
    other_owner = create_test_user(email_address: "other-remove-owner@example.test")
    other_organization, other_membership = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Remove Organization",
      slug: "other-remove-organization"
    )
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Memberships::Remove.new(
        actor: @owner,
        membership_id: other_membership.id
      ).call
    end

    assert_predicate other_membership.reload, :active?
  end
end
