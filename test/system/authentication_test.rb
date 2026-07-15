require "application_system_test_case"
require "active_job/test_helper"
require "action_mailer/test_helper"
require "nokogiri"
require "uri"

class AuthenticationTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  REGISTRATION_PASSWORD = "registration-password-123"
  RESET_OLD_PASSWORD = "reset-old-password-123"
  RESET_NEW_PASSWORD = "reset-new-password-456"

  setup do
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "user registers, verifies, signs in, handles a wrong password, and signs out" do
    visit new_registration_path

    fill_in "Name", with: "System User"
    fill_in "Email address", with: "SYSTEM@EXAMPLE.COM"
    fill_in "Password", with: REGISTRATION_PASSWORD
    fill_in "Confirm password", with: REGISTRATION_PASSWORD
    click_button "Create account"

    assert_current_path new_session_path
    assert_text RegistrationsController::GENERIC_NOTICE
    user = User.find_by!(email_address: "system@example.com")
    assert_nil user.email_verified_at
    assert_empty user.sessions
    assert_emails 1 do
      UserMailer.email_verification(user).deliver_now
    end

    visit mail_link_path(subject: "Verify your email address")
    assert_equal edit_email_verification_path, URI.parse(current_url).path
    assert_nil user.reload.email_verified_at
    click_button "Verify email address"

    assert_current_path new_session_path
    assert_text "Your email address has been verified. You can now sign in."
    assert user.reload.email_verified?

    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "wrong-password-123"
    click_button "Sign in"

    assert_current_path new_session_path
    assert_text SessionsController::INVALID_CREDENTIALS_MESSAGE
    assert_empty user.sessions.reload

    fill_in "Email address", with: user.email_address
    fill_in "Password", with: REGISTRATION_PASSWORD
    click_button "Sign in"

    assert_current_path root_path
    assert_text user.name
    assert_equal 1, user.sessions.reload.count

    click_button "Sign out"

    assert_current_path new_session_path
    assert_text "You have been signed out."
    assert_empty user.sessions.reload
  end

  test "user resets the password and only the new password can sign in" do
    user = create_verified_user

    visit new_password_path
    fill_in "Email address", with: user.email_address
    click_button "Send reset instructions"

    assert_current_path new_session_path
    assert_text PasswordsController::GENERIC_REQUEST_NOTICE
    assert_emails 1 do
      UserMailer.password_reset(user).deliver_now
    end

    visit mail_link_path(subject: "Reset your password")
    assert_equal edit_password_path, URI.parse(current_url).path
    fill_in "New password", with: RESET_NEW_PASSWORD
    fill_in "Confirm new password", with: RESET_NEW_PASSWORD
    click_button "Update password"

    assert_current_path new_session_path
    assert_text "Your password has been reset."

    fill_in "Email address", with: user.email_address
    fill_in "Password", with: RESET_OLD_PASSWORD
    click_button "Sign in"

    assert_current_path new_session_path
    assert_text SessionsController::INVALID_CREDENTIALS_MESSAGE

    fill_in "Email address", with: user.email_address
    fill_in "Password", with: RESET_NEW_PASSWORD
    click_button "Sign in"

    assert_current_path root_path
    assert_text user.name
  end

  private
    def create_verified_user
      User.create!(
        name: "Password System User",
        email_address: "password-system@example.com",
        password: RESET_OLD_PASSWORD,
        password_confirmation: RESET_OLD_PASSWORD,
        email_verified_at: Time.current
      )
    end

    def mail_link_path(subject:)
      message = ActionMailer::Base.deliveries.reverse.find { |mail| mail.subject == subject }
      assert_not_nil message, "Expected an email with subject #{subject.inspect}"

      document = Nokogiri::HTML(message.html_part.body.decoded)
      link = document.at_css("a")
      assert_not_nil link, "Expected the email to contain a link"
      href = link["href"]
      assert_not_nil href, "Expected the email to contain a link"

      uri = URI.parse(href)
      uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    end
end
