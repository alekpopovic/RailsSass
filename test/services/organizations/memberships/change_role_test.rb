require "test_helper"
require_relative "../../../support/organization_test_helper"

class Organizations::Memberships::ChangeRoleTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner
    )
  end

  teardown do
    Current.reset
  end

  test "owner can grant every organization role" do
    member = create_test_user(email_address: "role-target@example.test")
    target = create_test_membership(organization: @organization, user: member, role: :member)
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    %i[admin owner member billing].each do |role|
      updated = change_role(actor: @owner, membership: target, role: role)

      assert_predicate updated, :"#{role}?"
    end
  end

  test "admin can manage only member and admin roles" do
    admin = create_test_user(email_address: "admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    billing_user = create_test_user(email_address: "admin-billing-target@example.test")
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    manageable_member = create_test_user(email_address: "manageable@example.test")
    manageable = create_test_membership(
      organization: @organization,
      user: manageable_member,
      role: :member
    )
    establish_tenant_context(user: admin, organization: @organization, membership: admin_membership)

    assert_predicate change_role(actor: admin, membership: manageable, role: :admin), :admin?
    assert_predicate change_role(actor: admin, membership: manageable, role: :member), :member?

    [
      [ @owner_membership, :member ],
      [ billing_membership, :member ],
      [ manageable, :owner ],
      [ manageable, :billing ]
    ].each do |membership, role|
      assert_raises(Pundit::NotAuthorizedError) do
        change_role(actor: admin, membership: membership, role: role)
      end
    end
  end

  test "billing and member roles cannot manage memberships" do
    target_user = create_test_user(email_address: "denied-target@example.test")
    target = create_test_membership(
      organization: @organization,
      user: target_user,
      role: :member
    )

    %i[billing member].each do |role|
      actor = create_test_user(email_address: "#{role}-actor@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      establish_tenant_context(user: actor, organization: @organization, membership: actor_membership)

      assert_raises(Pundit::NotAuthorizedError) do
        change_role(actor: actor, membership: target, role: :admin)
      end
    end

    assert_predicate target.reload, :member?
  end

  test "suspended tenant state and stale actor authentication are denied" do
    target_user = create_test_user(email_address: "state-target@example.test")
    target = create_test_membership(
      organization: @organization,
      user: target_user,
      role: :member
    )
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)
    @organization.update!(status: :suspended)

    assert_raises(Pundit::NotAuthorizedError) do
      change_role(actor: @owner, membership: target, role: :admin)
    end

    @organization.update!(status: :active)

    [ :suspended, :disabled, :unverified ].each do |state|
      actor = create_test_user(email_address: "#{state}-actor@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: :admin
      )
      establish_tenant_context(user: actor, organization: @organization, membership: actor_membership)

      case state
      when :suspended
        @organization.organization_memberships
          .where(id: actor_membership.id)
          .update_all(status: "suspended", updated_at: Time.current)
      when :disabled
        User.find(actor.id).update!(disabled_at: Time.current)
      when :unverified
        User.find(actor.id).update!(email_address: "changed-#{actor.email_address}")
      end

      assert_raises(Pundit::NotAuthorizedError) do
        change_role(actor: actor, membership: target, role: :admin)
      end
    end

    assert_predicate target.reload, :member?
  end

  test "the last active owner cannot be demoted" do
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      change_role(actor: @owner, membership: @owner_membership, role: :admin)
    end

    assert_includes error.record.errors[:base], OrganizationMembership::LAST_ACTIVE_OWNER_MESSAGE
    assert_predicate @owner_membership.reload, :owner?
  end

  test "one owner may be demoted when another active owner remains" do
    second_owner = create_test_user(email_address: "second-owner@example.test")
    create_test_membership(
      organization: @organization,
      user: second_owner,
      role: :owner
    )
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    updated = change_role(actor: @owner, membership: @owner_membership, role: :admin)

    assert_predicate updated, :admin?
    assert_equal updated, Current.organization_membership
    assert_equal 1, @organization.organization_memberships.active_owners.count
  end

  test "target membership is always resolved through Current organization" do
    other_owner = create_test_user(email_address: "other-owner@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Organization",
      slug: "other-organization"
    )
    other_user = create_test_user(email_address: "other-member@example.test")
    other_membership = create_test_membership(
      organization: other_organization,
      user: other_user,
      role: :member
    )
    establish_tenant_context(user: @owner, organization: @organization, membership: @owner_membership)

    assert_raises(ActiveRecord::RecordNotFound) do
      change_role(actor: @owner, membership: other_membership, role: :admin)
    end

    assert_predicate other_membership.reload, :member?
  end

  test "platform admin system role grants no organization membership authority" do
    platform_admin = create_test_user(email_address: "platform-admin@example.test")
    platform_admin.update!(system_role: :platform_admin)
    platform_membership = create_test_membership(
      organization: @organization,
      user: platform_admin,
      role: :member
    )
    target_user = create_test_user(email_address: "platform-target@example.test")
    target = create_test_membership(
      organization: @organization,
      user: target_user,
      role: :member
    )
    establish_tenant_context(
      user: platform_admin,
      organization: @organization,
      membership: platform_membership
    )

    assert_raises(Pundit::NotAuthorizedError) do
      change_role(actor: platform_admin, membership: target, role: :admin)
    end

    assert_predicate platform_admin, :platform_admin?
    assert_predicate target.reload, :member?
  end

  private
    def change_role(actor:, membership:, role:)
      Organizations::Memberships::ChangeRole.new(
        actor: actor,
        membership_id: membership.id,
        role: role
      ).call
    end
end
