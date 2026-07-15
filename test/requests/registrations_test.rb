require "test_helper"
require_relative "../support/authentication_test_helper"

class RegistrationsRequestTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  setup do
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
  end

  test "registration creates only an unverified user and queues verification" do
    assert_no_difference [
      -> { Session.count },
      -> { Organization.count },
      -> { OrganizationMembership.count }
    ] do
      assert_difference -> { User.count }, 1 do
        post registration_path, params: {
          user: {
            name: "  New User  ",
            email_address: "  NEW.USER@EXAMPLE.TEST  ",
            password: TEST_PASSWORD,
            password_confirmation: TEST_PASSWORD
          }
        }
      end
    end

    user = User.order(:created_at).last

    assert_equal "New User", user.name
    assert_equal "new.user@example.test", user.email_address
    assert_not user.email_verified?
    assert_predicate user, :user?
    assert_redirected_to new_session_path
    assert_equal RegistrationsController::GENERIC_NOTICE, flash[:notice]
    assert_enqueued_email_with UserMailer, :email_verification, args: [ user ]
  end

  test "registration cannot assign the platform role" do
    post registration_path, params: {
      user: {
        name: "Ordinary User",
        email_address: "ordinary@example.test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        system_role: "platform_admin",
        email_verified_at: Time.current
      }
    }

    user = User.find_by!(email_address: "ordinary@example.test")

    assert_predicate user, :user?
    assert_not user.email_verified?
  end

  test "duplicate email receives the same generic response without exposing existence" do
    create_test_user(email_address: "existing@example.test")
    initial_user_count = User.count

    post registration_path, params: {
      user: {
        name: "First Registration",
        email_address: "first@example.test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD
      }
    }
    successful_response = registration_response

    assert_enqueued_emails 1

    post registration_path, params: {
      user: {
        name: "Duplicate Registration",
        email_address: "  EXISTING@EXAMPLE.TEST ",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD
      }
    }
    duplicate_response = registration_response

    assert_equal successful_response, duplicate_response
    assert_equal initial_user_count + 1, User.count
    assert_enqueued_emails 1

    follow_redirect!

    assert_response :success
    assert_select "[role='status']", text: RegistrationsController::GENERIC_NOTICE
    assert_no_match(/already|exists|taken/i, response.body)
  end

  test "registration is rate limited by remote address" do
    5.times do
      post registration_path, params: {
        user: {
          name: "Rate Limited User",
          email_address: "not-an-email",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD
        }
      }
    end

    assert_no_difference -> { User.count } do
      post registration_path, params: {
        user: {
          name: "Rate Limited User",
          email_address: "rate-limited@example.test",
          password: TEST_PASSWORD,
          password_confirmation: TEST_PASSWORD
        }
      }
    end

    assert_redirected_to new_registration_path
    assert_equal "Please wait before trying again.", flash[:alert]
  end

  private
    def registration_response
      {
        status: response.status,
        location: response.location,
        notice: flash[:notice],
        alert: flash[:alert]
      }
    end
end
