require "test_helper"
require_relative "../support/authentication_test_helper"

class ActiveSessionsRequestTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  test "user can list only their active sessions" do
    user = create_test_user(email_address: "owner@example.test")
    other_user = create_test_user(email_address: "other@example.test")
    current_session = sign_in_as(user)
    own_session, = Session.issue_for!(user, ip_address: "127.0.0.2", user_agent: "Own other browser")
    other_session, = Session.issue_for!(other_user, ip_address: "127.0.0.3", user_agent: "Other user browser")

    get active_sessions_path

    assert_response :success
    assert_select "form[action='#{active_session_path(current_session)}']"
    assert_select "form[action='#{active_session_path(own_session)}']"
    assert_select "form[action='#{active_session_path(other_session)}']", count: 0
  end

  test "user can revoke another one of their sessions" do
    user = create_test_user
    current_session = sign_in_as(user)
    other_session, = Session.issue_for!(user, ip_address: "127.0.0.2", user_agent: "Other browser")

    assert_difference -> { user.sessions.count }, -1 do
      delete active_session_path(other_session)
    end

    assert_response :see_other
    assert_redirected_to active_sessions_path
    assert Session.exists?(current_session.id)
    assert_not Session.exists?(other_session.id)
    assert cookies[Authentication::SESSION_COOKIE].present?
  end

  test "revoking the current session signs the user out" do
    user = create_test_user
    current_session = sign_in_as(user)

    assert_difference -> { user.sessions.count }, -1 do
      delete active_session_path(current_session)
    end

    assert_response :see_other
    assert_redirected_to new_session_path
    assert_not Session.exists?(current_session.id)
    assert cookies[Authentication::SESSION_COOKIE].blank?
  end

  test "user cannot revoke another user's session" do
    user = create_test_user(email_address: "owner@example.test")
    other_user = create_test_user(email_address: "other@example.test")
    current_session = sign_in_as(user)
    other_session, = Session.issue_for!(other_user, ip_address: "127.0.0.2", user_agent: "Other user")

    assert_no_difference -> { Session.count } do
      delete active_session_path(other_session)
    end

    assert_response :not_found
    assert Session.exists?(current_session.id)
    assert Session.exists?(other_session.id)
  end
end
