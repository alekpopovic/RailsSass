require "test_helper"
require_relative "../support/organization_test_helper"

class UserPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  teardown do
    Current.reset
  end

  test "allows a live authenticated user to view and update only their profile" do
    user = create_test_user(email_address: "profile-policy@example.test")
    other_user = create_test_user(email_address: "other-profile-policy@example.test")
    establish_tenant_context(user: user, organization: nil, membership: nil)
    context = AuthorizationContext.current

    assert UserPolicy.new(context, user).show?
    assert UserPolicy.new(context, user).update?
    assert_not UserPolicy.new(context, other_user).show?
    assert_not UserPolicy.new(context, other_user).update?
  end

  test "fails closed after session revocation or account disablement" do
    user = create_test_user(email_address: "revoked-profile-policy@example.test")
    session_record = establish_tenant_context(user: user, organization: nil, membership: nil)
    context = AuthorizationContext.current

    Session.where(id: session_record.id).delete_all
    assert_not UserPolicy.new(context, user).show?

    Current.reset
    disabled = create_test_user(email_address: "disabled-profile-policy@example.test")
    establish_tenant_context(user: disabled, organization: nil, membership: nil)
    disabled.update!(disabled_at: Time.current)

    assert_not UserPolicy.new(AuthorizationContext.current, disabled).update?
  end
end
