require "test_helper"
require "active_job/test_helper"
require "action_mailer/test_helper"
require "active_support/testing/time_helpers"

class PasswordsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  OLD_PASSWORD = "old-password-123"
  NEW_PASSWORD = "new-password-456"

  test "reset requests use the same response for known and unknown emails" do
    user = create_user

    assert_enqueued_emails 1 do
      post password_path, params: { email_address: "  RESET@EXAMPLE.COM " }
    end
    assert_redirected_to new_session_path
    assert_equal PasswordsController::GENERIC_REQUEST_NOTICE, flash[:notice]

    assert_no_enqueued_emails do
      post password_path, params: { email_address: "unknown@example.com" }
    end
    assert_redirected_to new_session_path
    assert_equal PasswordsController::GENERIC_REQUEST_NOTICE, flash[:notice]

    assert_equal "reset@example.com", user.email_address
  end

  test "the sixth reset request is rate limited without queuing another email" do
    user = create_user

    5.times do
      assert_enqueued_emails 1 do
        post password_path, params: { email_address: user.email_address }
      end
      assert_redirected_to new_session_path
    end

    assert_no_enqueued_emails do
      post password_path, params: { email_address: user.email_address }
    end
    assert_redirected_to new_password_path
    assert_equal "Please wait before trying again.", flash[:alert]
  end

  test "reset changes the password, revokes sessions, and cannot reuse the token" do
    user = create_user
    2.times do
      Session.issue_for!(user, ip_address: "127.0.0.1", user_agent: "Password test")
    end
    token = user.password_reset_token

    get edit_password_path(token: token)
    assert_response :success
    assert user.reload.authenticate(OLD_PASSWORD)

    patch password_path, params: {
      token: token,
      user: { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }
    }

    assert_redirected_to new_session_path
    assert_equal "Your password has been reset.", flash[:notice]
    assert user.reload.authenticate(NEW_PASSWORD)
    refute user.authenticate(OLD_PASSWORD)
    assert_empty user.sessions.reload

    password_digest = user.password_digest
    patch password_path, params: {
      token: token,
      user: { password: OLD_PASSWORD, password_confirmation: OLD_PASSWORD }
    }

    assert_redirected_to new_password_path
    assert_equal PasswordsController::INVALID_TOKEN_MESSAGE, flash[:alert]
    assert_equal password_digest, user.reload.password_digest
    assert user.authenticate(NEW_PASSWORD)
  end

  test "expired reset token cannot change the password" do
    user = create_user
    token = user.password_reset_token

    travel 16.minutes do
      patch password_path, params: {
        token: token,
        user: { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }
      }

      assert_redirected_to new_password_path
      assert_equal PasswordsController::INVALID_TOKEN_MESSAGE, flash[:alert]
    end

    assert user.reload.authenticate(OLD_PASSWORD)
    refute user.authenticate(NEW_PASSWORD)
  end

  private
    def create_user
      User.create!(
        name: "Reset User",
        email_address: "reset@example.com",
        password: OLD_PASSWORD,
        password_confirmation: OLD_PASSWORD,
        email_verified_at: Time.current
      )
    end
end
