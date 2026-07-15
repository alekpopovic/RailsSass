require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  setup do
    user = User.create!(
      name: "Current User",
      email_address: "current-user@example.test",
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple",
      email_verified_at: Time.current
    )
    @session, = Session.issue_for!(user, ip_address: nil, user_agent: nil)
  end

  teardown do
    Current.reset
  end

  test "delegates the user through the current session" do
    Current.session = @session

    assert_equal @session, Current.session
    assert_equal @session.user, Current.user
  end

  test "reset clears both session and delegated user" do
    Current.session = @session

    Current.reset

    assert_nil Current.session
    assert_nil Current.user
  end
end
