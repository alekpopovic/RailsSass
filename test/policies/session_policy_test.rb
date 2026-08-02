require "test_helper"
require_relative "../support/organization_test_helper"

class SessionPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  teardown do
    Current.reset
  end

  test "allows only a live user to list and revoke their own sessions" do
    user = create_test_user(email_address: "session-policy-user@example.test")
    current_session = establish_account_context(user)
    other_session, = Session.issue_for!(user, ip_address: nil, user_agent: "Other session")
    other_user = create_test_user(email_address: "session-policy-other@example.test")
    foreign_session, = Session.issue_for!(other_user, ip_address: nil, user_agent: "Foreign session")
    context = AuthorizationContext.current

    assert SessionPolicy.new(context, Session).index?
    assert SessionPolicy.new(context, other_session).destroy?
    assert_not SessionPolicy.new(context, foreign_session).destroy?
    assert_equal [ current_session, other_session ].sort_by(&:id),
      SessionPolicy::Scope.new(context, Session.all).resolve.order(:id).to_a
  end

  test "denies a revoked Current session" do
    user = create_test_user(email_address: "session-policy-revoked@example.test")
    current_session = establish_account_context(user)
    context = AuthorizationContext.current
    Session.where(id: current_session.id).delete_all

    assert_not SessionPolicy.new(context, Session).index?
    assert_empty SessionPolicy::Scope.new(context, Session.all).resolve
  end

  private
    def establish_account_context(user)
      Current.session, = Session.issue_for!(user, ip_address: nil, user_agent: "Session policy test")
      Current.session
    end
end
