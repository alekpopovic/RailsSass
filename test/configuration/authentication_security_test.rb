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

  BILLING_SENSITIVE_VALUES = {
    authorization: "Bearer provider-key",
    api_key: "provider-key",
    signature: "webhook-signature",
    raw_payload: { "customer_email" => "person@example.test" },
    checkout_url: "https://provider.example/signed-checkout",
    portal_url: "https://provider.example/signed-portal"
  }.freeze

  test "authentication secrets are filtered from structured parameters" do
    filtered = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(SENSITIVE_VALUES)

    assert_equal [ "[FILTERED]" ], filtered.values.uniq
  end

  test "billing credentials and sensitive payload fields are filtered" do
    filtered = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(BILLING_SENSITIVE_VALUES)

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

  test "authentication mail bodies are not written to application logs" do
    assert_nil ActionMailer::Base.logger
  end

  test "secret-bearing links do not place tokens in route path segments" do
    assert_equal "/password/edit", Rails.application.routes.url_helpers.edit_password_path
    assert_equal "/email_verification/edit",
      Rails.application.routes.url_helpers.edit_email_verification_path
  end

  test "internal return paths reject encoded protocol-relative and backslash forms" do
    controller = ApplicationController.new

    assert_equal "/active_sessions", controller.send(:safe_internal_path, "/active_sessions")
    assert_nil controller.send(:safe_internal_path, "/%2f%2fattacker.example")
    assert_nil controller.send(:safe_internal_path, "/%5cattacker.example")
    assert_nil controller.send(:safe_internal_path, "https://attacker.example")
  end
end
