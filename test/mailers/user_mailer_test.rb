require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  setup do
    @user = User.create!(
      name: "Mailer User",
      email_address: "mailer@example.com",
      password: "a secure password",
      password_confirmation: "a secure password"
    )
  end

  test "password reset email contains a filtered-query-compatible one-use link" do
    email = UserMailer.password_reset(@user).deliver_now
    reset_uri = URI.parse(URI.extract(email.text_part.body.to_s, %w[http https]).first)

    assert_equal [ @user.email_address ], email.to
    assert_equal "Reset your password", email.subject
    assert_equal "/password/edit", reset_uri.path
    assert_predicate Rack::Utils.parse_nested_query(reset_uri.query)["token"], :present?
  end

  test "verification email contains a confirmation link without a path token" do
    email = UserMailer.email_verification(@user).deliver_now
    verification_uri = URI.parse(URI.extract(email.text_part.body.to_s, %w[http https]).first)

    assert_equal [ @user.email_address ], email.to
    assert_equal "Verify your email address", email.subject
    assert_equal "/email_verification/edit", verification_uri.path
    assert_predicate Rack::Utils.parse_nested_query(verification_uri.query)["token"], :present?
  end
end
