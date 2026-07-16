require "test_helper"
require_relative "../support/organization_test_helper"

class PlatformAdminPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  teardown do
    Current.reset
  end

  test "allows a live verified platform administrator and resolves the supplied scope" do
    administrator = create_test_user(email_address: "platform-policy-admin@example.test")
    administrator.update!(system_role: :platform_admin)
    ordinary_user = create_test_user(email_address: "platform-policy-user@example.test")
    establish_account_context(administrator)
    context = AuthorizationContext.current
    supplied_scope = User.where(id: [ administrator.id, ordinary_user.id ])

    assert PlatformAdminPolicy.new(context, :platform_admin).access?
    assert_equal supplied_scope.order(:id).to_a,
      PlatformAdminPolicy::Scope.new(context, supplied_scope).resolve.order(:id).to_a
  end

  test "denies an authenticated ordinary user even when the user owns an organization" do
    owner = create_test_user(email_address: "platform-policy-owner@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: owner,
      name: "Platform Policy Owner",
      slug: "platform-policy-owner"
    )
    establish_account_context(owner, organization:, membership:)
    context = AuthorizationContext.current

    assert_not PlatformAdminPolicy.new(context, :platform_admin).access?
    assert_empty PlatformAdminPolicy::Scope.new(context, User.all).resolve
  end

  test "denies unverified disabled and unauthenticated platform administrators" do
    unverified = create_test_user(
      email_address: "platform-policy-unverified@example.test",
      verified: false
    )
    unverified.update!(system_role: :platform_admin)
    establish_account_context(unverified)
    assert_not PlatformAdminPolicy.new(AuthorizationContext.current, :platform_admin).access?

    Current.reset
    disabled = create_test_user(
      email_address: "platform-policy-disabled@example.test",
      disabled_at: Time.current
    )
    disabled.update!(system_role: :platform_admin)
    establish_account_context(disabled)
    assert_not PlatformAdminPolicy.new(AuthorizationContext.current, :platform_admin).access?

    Current.reset
    assert_not PlatformAdminPolicy.new(
      AuthorizationContext.new(user: disabled, organization: nil, membership: nil),
      :platform_admin
    ).access?
  end

  test "uses the persisted system role rather than a stale in-memory role" do
    administrator = create_test_user(email_address: "platform-policy-stale@example.test")
    administrator.update!(system_role: :platform_admin)
    establish_account_context(administrator)
    context = AuthorizationContext.current

    User.where(id: administrator.id).update_all(system_role: "user", updated_at: Time.current)

    assert_predicate administrator, :platform_admin?
    assert_not PlatformAdminPolicy.new(context, :platform_admin).access?
    assert_empty PlatformAdminPolicy::Scope.new(context, User.all).resolve
  end

  private
    def establish_account_context(user, organization: nil, membership: nil)
      Current.session, = Session.issue_for!(user, ip_address: nil, user_agent: "Minitest")
      Current.organization = organization
      Current.membership = membership
    end
end
