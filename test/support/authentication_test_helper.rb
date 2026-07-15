module AuthenticationTestHelper
  TEST_PASSWORD = "correct horse battery staple"

  def create_test_user(
    name: "Test User",
    email_address: "user@example.test",
    password: TEST_PASSWORD,
    verified: true,
    disabled_at: nil
  )
    User.create!(
      name: name,
      email_address: email_address,
      password: password,
      password_confirmation: password,
      email_verified_at: verified ? Time.current : nil,
      disabled_at: disabled_at
    )
  end

  def sign_in_as(user, password: TEST_PASSWORD)
    post session_path, params: {
      email_address: user.email_address,
      password: password
    }

    assert_redirected_to root_path
    user.sessions.order(:created_at).last!
  end

  def session_token_set_cookie
    Array(response.headers["Set-Cookie"])
      .flat_map { |header| header.split("\n") }
      .find { |header| header.start_with?("#{Authentication::SESSION_COOKIE}=") }
  end
end
