require "test_helper"
require_relative "../support/authentication_test_helper"

class SessionsRequestTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  test "verified user signs in with a normalized email" do
    user = create_test_user(email_address: "normalized@example.test")

    assert_difference -> { user.sessions.count }, 1 do
      post session_path, params: {
        email_address: "  NORMALIZED@EXAMPLE.TEST ",
        password: TEST_PASSWORD
      }
    end

    assert_redirected_to root_path
    assert cookies[Authentication::SESSION_COOKIE].present?
  end

  test "wrong password unknown email unverified user and disabled user have identical failures" do
    verified_user = create_test_user(email_address: "verified@example.test")
    unverified_user = create_test_user(email_address: "unverified@example.test", verified: false)
    disabled_user = create_test_user(
      email_address: "disabled@example.test",
      disabled_at: Time.current
    )

    attempts = [
      [ verified_user.email_address, "incorrect password" ],
      [ "unknown@example.test", TEST_PASSWORD ],
      [ unverified_user.email_address, TEST_PASSWORD ],
      [ disabled_user.email_address, TEST_PASSWORD ]
    ]

    responses = assert_no_difference -> { Session.count } do
      attempts.map { |email_address, password| failed_login_response(email_address, password) }
    end

    assert_equal 1, responses.uniq.size
    assert_equal SessionsController::INVALID_CREDENTIALS_MESSAGE, responses.first.fetch(:alert)
    assert_nil cookies[Authentication::SESSION_COOKIE]
  end

  test "logout destroys only the current session" do
    user = create_test_user
    current_session = sign_in_as(user)
    other_session, = Session.issue_for!(user, ip_address: "127.0.0.2", user_agent: "Other browser")

    assert_difference -> { user.sessions.count }, -1 do
      delete session_path
    end

    assert_response :see_other
    assert_redirected_to new_session_path
    assert_not Session.exists?(current_session.id)
    assert Session.exists?(other_session.id)
    assert cookies[Authentication::SESSION_COOKIE].blank?
  end

  test "signing in again rotates the browser token and revokes the previous session" do
    user = create_test_user
    first_session = sign_in_as(user)
    first_cookie = cookies[Authentication::SESSION_COOKIE]

    second_session = sign_in_as(user)

    assert_not_equal first_session, second_session
    assert_not_equal first_cookie, cookies[Authentication::SESSION_COOKIE]
    assert_not Session.exists?(first_session.id)
    assert Session.exists?(second_session.id)
    assert_equal 1, user.sessions.count
  end

  test "login returns to a stored internal path" do
    user = create_test_user

    get active_sessions_path

    assert_redirected_to new_session_path

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    assert_redirected_to active_sessions_path
  end

  test "an oversized protected location is not stored and login falls back safely" do
    user = create_test_user

    get active_sessions_path, params: { oversized: "a" * 5.kilobytes }

    assert_redirected_to new_session_path
    assert_nil request.session[:return_to_after_authenticating]

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    assert_redirected_to root_path
  end

  test "login ignores a caller supplied external return location" do
    user = create_test_user

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD,
      return_to: "https://attacker.example/steal"
    }

    assert_redirected_to root_path
    assert_not_includes response.location, "attacker.example"
  end

  test "session cookie is HttpOnly and SameSite Lax" do
    user = create_test_user

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    cookie_header = session_token_set_cookie

    assert cookie_header
    assert_match(/; httponly/i, cookie_header)
    assert_match(/; samesite=lax/i, cookie_header)
  end

  test "session cookie is Secure in production" do
    user = create_test_user
    https!
    original_production_check = Rails.env.method(:production?)
    Rails.env.define_singleton_method(:production?) { true }

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    cookie_header = session_token_set_cookie

    assert cookie_header
    assert_match(/; secure/i, cookie_header)
  ensure
    Rails.env.define_singleton_method(:production?, original_production_check)
  end

  test "login rejects a request without a CSRF token when forgery protection is enabled" do
    user = create_test_user
    original_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference -> { Session.count } do
      post session_path, params: {
        email_address: user.email_address,
        password: TEST_PASSWORD
      }
    end

    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = original_setting
  end

  test "logout rejects a request without a CSRF token when forgery protection is enabled" do
    user = create_test_user
    current_session = sign_in_as(user)
    original_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference -> { Session.count } do
      delete session_path
    end

    assert_response :unprocessable_content
    assert Session.exists?(current_session.id)
    assert cookies[Authentication::SESSION_COOKIE].present?
  ensure
    ActionController::Base.allow_forgery_protection = original_setting
  end

  test "login is rate limited by remote address" do
    user = create_test_user

    10.times do
      post session_path, params: {
        email_address: user.email_address,
        password: "incorrect password"
      }
    end

    assert_no_difference -> { Session.count } do
      post session_path, params: {
        email_address: user.email_address,
        password: TEST_PASSWORD
      }
    end

    assert_redirected_to new_session_path
    assert_equal SessionsController::INVALID_CREDENTIALS_MESSAGE, flash[:alert]
  end

  private
    def failed_login_response(email_address, password)
      post session_path, params: { email_address: email_address, password: password }

      {
        status: response.status,
        location: response.location,
        alert: flash[:alert]
      }
    end
end
