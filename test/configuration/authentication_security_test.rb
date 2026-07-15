require "test_helper"

class AuthenticationSecurityTest < ActiveSupport::TestCase
  SENSITIVE_VALUES = {
    password: "password-value",
    password_confirmation: "confirmation-value",
    reset_token: "reset-value",
    verification_token: "verification-value",
    session_token: "session-value",
    token_digest: "digest-value"
  }.freeze

  test "authentication secrets are filtered from structured parameters" do
    filtered = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(SENSITIVE_VALUES)

    assert_equal [ "[FILTERED]" ], filtered.values.uniq
  end

  test "token query values are filtered from the request path used by Rails logging" do
    request_env = Rack::MockRequest.env_for(
      "/password/edit?token=reset-value&verification_token=verification-value&session_token=session-value"
    )
    request = ActionDispatch::Request.new(Rails.application.env_config.merge(request_env))

    assert_equal "/password/edit?token=[FILTERED]&verification_token=[FILTERED]&session_token=[FILTERED]",
      request.filtered_path
  end

  test "secret-bearing links do not place tokens in route path segments" do
    assert_equal "/password/edit", Rails.application.routes.url_helpers.edit_password_path
    assert_equal "/email_verification/edit",
      Rails.application.routes.url_helpers.edit_email_verification_path
  end
end
