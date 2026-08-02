require "test_helper"
require_relative "../../support/organization_test_helper"

class Organizations::CreateTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @user = create_test_user(email_address: "organization-creator@example.test")
    @session, = Session.issue_for!(@user, ip_address: nil, user_agent: "Minitest")
    Current.session = @session
  end

  teardown do
    Current.reset
  end

  test "atomically creates an active organization and its first owner" do
    organization = nil

    assert_difference [
      -> { Organization.count },
      -> { OrganizationMembership.count },
      -> { OrganizationAccessLocator.count }
    ], 1 do
      assert_difference -> { AuditEvent.count }, 2 do
        organization = Organizations::Create.new(
          user: @user,
          name: "  Example Company  ",
          slug: " Example Company "
        ).call
      end
    end

    membership = organization.organization_memberships.sole

    assert_equal "Example Company", organization.name
    assert_equal "example-company", organization.slug
    assert_predicate organization, :active?
    assert_equal @user, membership.user
    assert_predicate membership, :owner?
    assert_predicate membership, :active?
    assert_in_delta Time.current, membership.joined_at, 1.second
    assert_equal membership, membership.organization_access_locator.organization_membership
    assert_equal @user, membership.organization_access_locator.user
    assert_equal organization, membership.organization_access_locator.organization
    assert_equal %w[organization.created organization.membership.created],
      organization.audit_events.order(:id).pluck(:action)
  end

  test "requires the explicitly authenticated verified and enabled user" do
    unverified_user = create_test_user(
      email_address: "unverified-creator@example.test",
      verified: false
    )
    disabled_user = create_test_user(
      email_address: "disabled-creator@example.test",
      disabled_at: Time.current
    )

    [ unverified_user, disabled_user ].each do |user|
      Current.session, = Session.issue_for!(user, ip_address: nil, user_agent: "Minitest")

      assert_no_difference [
        -> { Organization.count },
        -> { OrganizationMembership.count },
        -> { OrganizationAccessLocator.count }
      ] do
        assert_raises(Pundit::NotAuthorizedError) do
          Organizations::Create.new(user: user, name: "Denied", slug: "denied").call
        end
      end
    end

    Current.session = @session

    assert_raises(Pundit::NotAuthorizedError) do
      Organizations::Create.new(
        user: disabled_user,
        name: "Mismatched User",
        slug: "mismatched-user"
      ).call
    end
  end

  test "a failed organization leaves no membership and preserves the previous Current context" do
    existing_organization, existing_membership = create_test_organization_with_owner(
      owner: @user,
      slug: "existing-organization"
    )
    Current.organization = existing_organization
    Current.membership = existing_membership

    assert_no_difference [
      -> { Organization.count },
      -> { OrganizationMembership.count },
      -> { OrganizationAccessLocator.count }
    ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Organizations::Create.new(user: @user, name: "", slug: "").call
      end
    end

    assert_equal existing_organization, Current.organization
    assert_equal existing_membership, Current.membership
  end

  test "uses authoritative verification state instead of a stale user object" do
    User.find(@user.id).update!(email_address: "changed-creator@example.test")

    assert_predicate @user, :email_verified?
    assert_no_difference [
      -> { Organization.count },
      -> { OrganizationMembership.count },
      -> { OrganizationAccessLocator.count }
    ] do
      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::Create.new(
          user: @user,
          name: "Stale Authentication",
          slug: "stale-authentication"
        ).call
      end
    end
  end

  test "a revoked Current session cannot create an organization" do
    Session.where(id: @session.id).delete_all

    assert_no_difference [
      -> { Organization.count },
      -> { OrganizationMembership.count },
      -> { OrganizationAccessLocator.count },
      -> { AuditEvent.count }
    ] do
      assert_raises(Pundit::NotAuthorizedError) do
        Organizations::Create.new(
          user: @user,
          name: "Revoked Session Organization",
          slug: "revoked-session-organization"
        ).call
      end
    end
  end

  test "platform system role does not replace the organization owner role" do
    platform_admin = create_test_user(
      email_address: "platform-creator@example.test"
    )
    platform_admin.update!(system_role: :platform_admin)
    Current.session, = Session.issue_for!(platform_admin, ip_address: nil, user_agent: "Minitest")

    organization = Organizations::Create.new(
      user: platform_admin,
      name: "Platform Admin Organization",
      slug: "platform-admin-organization"
    ).call

    assert_predicate platform_admin, :platform_admin?
    assert_predicate organization.organization_memberships.sole, :owner?
  end
end
