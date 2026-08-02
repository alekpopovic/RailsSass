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
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
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

  test "verification update rate limiting runs before token lookup" do
    user = create_user
    token = user.email_verification_token
    user.update!(disabled_at: Time.current)

    10.times do
      patch email_verification_path, params: { token: token }
      assert_redirected_to new_session_path
    end

    user_queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      user_queries << payload[:sql] if payload[:sql].include?('FROM "users"')
    end
    patch email_verification_path, params: { token: token }

    assert_redirected_to new_session_path
    assert_equal EmailVerificationsController::INVALID_TOKEN_MESSAGE, flash[:alert]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_empty user_queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "verification request and update reject missing CSRF tokens" do
    user = create_user
    token = user.email_verification_token
    original_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_enqueued_emails do
      post email_verification_path, params: { email_address: user.email_address }
    end
    assert_response :unprocessable_content

    patch email_verification_path, params: { token: token }

    assert_response :unprocessable_content
    assert_nil user.reload.email_verified_at
  ensure
    ActionController::Base.allow_forgery_protection = original_setting
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
