require "test_helper"
require "active_job/test_helper"
require "action_mailer/test_helper"
require "active_support/testing/time_helpers"

class EmailVerificationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  PASSWORD = "verification-password-123"

  test "verification requests use the same response for known and unknown emails" do
    user = create_user

    assert_enqueued_emails 1 do
      post email_verification_path, params: { email_address: "  VERIFY@EXAMPLE.COM " }
    end
    assert_redirected_to new_session_path
    assert_equal EmailVerificationsController::GENERIC_REQUEST_NOTICE, flash[:notice]

    assert_no_enqueued_emails do
      post email_verification_path, params: { email_address: "unknown@example.com" }
    end
    assert_redirected_to new_session_path
    assert_equal EmailVerificationsController::GENERIC_REQUEST_NOTICE, flash[:notice]

    assert_nil user.reload.email_verified_at
  end

  test "the sixth verification request is rate limited without queuing another email" do
    user = create_user

    5.times do
      assert_enqueued_emails 1 do
        post email_verification_path, params: { email_address: user.email_address }
      end
      assert_redirected_to new_session_path
    end

    assert_no_enqueued_emails do
      post email_verification_path, params: { email_address: user.email_address }
    end
    assert_redirected_to new_email_verification_path
    assert_equal "Please wait before trying again.", flash[:alert]
  end

  test "GET only renders confirmation and PATCH verifies exactly once" do
    user = create_user
    token = user.email_verification_token

    get edit_email_verification_path(token: token)

    assert_response :success
    assert_nil user.reload.email_verified_at
    assert_select "form[action=?]", email_verification_path

    patch email_verification_path, params: { token: token }

    assert_redirected_to new_session_path
    assert_equal "Your email address has been verified. You can now sign in.", flash[:notice]
    verified_at = user.reload.email_verified_at
    assert_not_nil verified_at

    patch email_verification_path, params: { token: token }

    assert_redirected_to new_session_path
    assert_equal EmailVerificationsController::INVALID_TOKEN_MESSAGE, flash[:alert]
    assert_equal verified_at, user.reload.email_verified_at
  end

  test "expired verification token cannot verify the email" do
    user = create_user
    token = user.email_verification_token

    travel 25.hours do
      patch email_verification_path, params: { token: token }

      assert_redirected_to new_session_path
      assert_equal EmailVerificationsController::INVALID_TOKEN_MESSAGE, flash[:alert]
    end

    assert_nil user.reload.email_verified_at
  end

  test "successful verification preserves onboarding through failed and successful login" do
    user = create_user
    token = user.email_verification_token

    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      patch email_verification_path, params: { token: token }
    end

    assert_redirected_to new_session_path
    assert_no_difference [ -> { Organization.count }, -> { OrganizationMembership.count } ] do
      post session_path, params: {
        email_address: user.email_address,
        password: "incorrect password"
      }
    end
    assert_redirected_to new_session_path

    post session_path, params: {
      email_address: user.email_address,
      password: PASSWORD
    }

    assert_redirected_to new_organization_path
  end

  private
    def create_user
      User.create!(
        name: "Verification User",
        email_address: "verify@example.com",
        password: PASSWORD,
        password_confirmation: PASSWORD
      )
    end
end
