require "test_helper"
require "webmock/minitest"

class Billing::LemonSqueezy::ClientTest < ActiveSupport::TestCase
  BASE_URL = "https://api.lemonsqueezy.com"
  API_KEY = "synthetic-test-api-key"
  STORE_ID = "synthetic-test-store"

  setup do
    @client = build_client
  end

  test "retrieves and parses a subscription with the required headers" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/sub_123").to_return(
      status: 200,
      body: { data: { type: "subscriptions", id: "sub_123" } }.to_json
    )

    response = nil
    assert_no_difference -> { Billing::Subscription.count } do
      response = @client.retrieve_subscription(provider_subscription_id: "sub_123")
    end

    assert_equal "sub_123", response.dig("data", "id")
    assert_requested(
      :get,
      "#{BASE_URL}/v1/subscriptions/sub_123",
      headers: {
        "Accept" => "application/vnd.api+json",
        "Authorization" => "Bearer #{API_KEY}",
        "Content-Type" => "application/vnd.api+json"
      },
      times: 1
    )
  end

  test "uses explicit bounded connection and read timeouts" do
    client = build_client(open_timeout: 1.25, read_timeout: 4.5)

    assert_equal 1.25, client.open_timeout
    assert_equal 4.5, client.read_timeout
    assert_equal 1.25, client.send(:connection).options.open_timeout
    assert_equal 4.5, client.send(:connection).options.timeout
    assert_equal 1.25, client.send(:connection).options.open_timeout
    assert_equal 4.5, client.send(:connection).options.timeout

    invalid_timeout = "sensitive-timeout-input"
    error = assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      build_client(open_timeout: invalid_timeout)
    end
    assert_nil error.cause
    assert_not_includes error.full_message, invalid_timeout
    assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      build_client(read_timeout: Float::INFINITY)
    end
  end

  test "loads configuration in explicit environment credentials order" do
    env = {
      "LEMON_SQUEEZY_API_KEY" => "environment-api-key",
      "LEMON_SQUEEZY_STORE_ID" => "environment-store"
    }
    credentials = {
      lemon_squeezy: {
        api_key: "credential-api-key",
        store_id: "credential-store"
      }
    }

    explicit_client = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      env:,
      credentials:
    )
    environment_client = described_class.new(env:, credentials:)
    credential_client = described_class.new(env: {}, credentials:)

    assert_equal STORE_ID, explicit_client.store_id
    assert_equal "environment-store", environment_client.store_id
    assert_equal "credential-store", credential_client.store_id

    assert_client_uses_api_key(explicit_client, "explicit", API_KEY)
    assert_client_uses_api_key(environment_client, "environment", "environment-api-key")
    assert_client_uses_api_key(credential_client, "credentials", "credential-api-key")
  end

  test "rejects missing configuration before making a request" do
    assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      described_class.new(env: {}, credentials: {})
    end
    assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      described_class.new(api_key: API_KEY, env: {}, credentials: {})
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "returns nil for a no-content success" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/sub_204").to_return(status: 204)

    assert_nil @client.retrieve_subscription(provider_subscription_id: "sub_204")
  end

  test "rejects blank malformed non-object and oversized success bodies" do
    invalid_bodies = {
      "blank" => "",
      "malformed" => "{",
      "array" => "[]",
      "oversized" => "{\"value\":\"#{"x" * 1_048_576}\"}"
    }

    invalid_bodies.each do |subscription_id, body|
      stub_request(:get, "#{BASE_URL}/v1/subscriptions/#{subscription_id}").to_return(
        status: 200,
        body:
      )

      error = assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError) do
        @client.retrieve_subscription(provider_subscription_id: subscription_id)
      end

      assert_equal 200, error.status
      assert_not error.retryable?
    end
  end

  test "maps client response statuses without exposing response bodies" do
    cases = {
      400 => Billing::LemonSqueezy::Errors::ClientError,
      401 => Billing::LemonSqueezy::Errors::AuthenticationError,
      403 => Billing::LemonSqueezy::Errors::AuthenticationError,
      404 => Billing::LemonSqueezy::Errors::NotFoundError
    }

    cases.each do |status, error_class|
      subscription_id = "status_#{status}"
      stub_request(:get, "#{BASE_URL}/v1/subscriptions/#{subscription_id}").to_return(
        status:,
        body: "sensitive-provider-response"
      )

      error = assert_raises(error_class) do
        @client.retrieve_subscription(provider_subscription_id: subscription_id)
      end

      assert_equal status, error.status
      assert_not error.retryable?
      assert_not_includes error.full_message, "sensitive-provider-response"
      assert_nil error.cause
    end
  end

  test "maps rate limiting with a bounded retry after value" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/rate_limited").to_return(
      status: 429,
      headers: { "Retry-After" => "7200" }
    )

    error = assert_raises(Billing::LemonSqueezy::Errors::RateLimitError) do
      @client.retrieve_subscription(provider_subscription_id: "rate_limited")
    end

    assert_equal 429, error.status
    assert_equal 3_600, error.retry_after
    assert error.retryable?
  end

  test "maps server errors as retryable but makes one request" do
    stub_request(:post, "#{BASE_URL}/v1/checkouts").to_return(status: 503)

    error = assert_raises(Billing::LemonSqueezy::Errors::ServerError) do
      @client.send(:request, method: :post, path: "/v1/checkouts", body: { data: { type: "checkouts" } })
    end

    assert_equal 503, error.status
    assert error.retryable?
    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: 1
  end

  test "does not retry an ambiguous timed-out post" do
    stub_request(:post, "#{BASE_URL}/v1/checkouts").to_timeout

    error = assert_raises(Billing::LemonSqueezy::Errors::TimeoutError) do
      @client.send(:request, method: :post, path: "/v1/checkouts", body: { data: { type: "checkouts" } })
    end

    assert error.retryable?
    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: 1
  end

  test "maps timeouts and connection failures to safe retryable errors" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/timed_out").to_timeout
    timeout_error = assert_raises(Billing::LemonSqueezy::Errors::TimeoutError) do
      @client.retrieve_subscription(provider_subscription_id: "timed_out")
    end

    stub_request(:get, "#{BASE_URL}/v1/subscriptions/disconnected").to_raise(
      Faraday::ConnectionFailed.new("sensitive transport detail")
    )
    connection_error = assert_raises(Billing::LemonSqueezy::Errors::ConnectionError) do
      @client.retrieve_subscription(provider_subscription_id: "disconnected")
    end

    assert timeout_error.retryable?
    assert connection_error.retryable?
    assert_nil timeout_error.cause
    assert_nil connection_error.cause
    assert_not_includes connection_error.full_message, "sensitive transport detail"
  end

  test "does not follow redirects" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/redirected").to_return(
      status: 302,
      headers: { "Location" => "https://example.test/sensitive" }
    )

    error = assert_raises(Billing::LemonSqueezy::Errors::UnexpectedResponseError) do
      @client.retrieve_subscription(provider_subscription_id: "redirected")
    end

    assert_equal 302, error.status
    assert_not_requested :get, "https://example.test/sensitive"
  end

  test "rejects unsafe identifiers and request paths before network access" do
    [ "", "../subscriptions/1", "1/portal", "https://example.test", "1\r\nX-Test: value" ].each do |identifier|
      assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
        @client.retrieve_subscription(provider_subscription_id: identifier)
      end
    end

    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      @client.send(:request, method: :get, path: "/v1/subscriptions/../secrets")
    end
    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      @client.send(:request, method: :trace, path: "/v1/subscriptions/1")
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "redacts configuration from inspection and raised errors" do
    stub_request(:get, "#{BASE_URL}/v1/subscriptions/redacted").to_return(
      status: 401,
      body: "provider-secret-body"
    )

    error = assert_raises(Billing::LemonSqueezy::Errors::AuthenticationError) do
      @client.retrieve_subscription(provider_subscription_id: "redacted")
    end

    [ @client.inspect, error.full_message ].each do |output|
      assert_not_includes output, API_KEY
      assert_not_includes output, STORE_ID
      assert_not_includes output, "provider-secret-body"
    end
  end

  private
    def described_class
      Billing::LemonSqueezy::Client
    end

    def build_client(**options)
      described_class.new(
        api_key: API_KEY,
        store_id: STORE_ID,
        env: {},
        credentials: {},
        **options
      )
    end

    def assert_client_uses_api_key(client, suffix, api_key)
      subscription_id = "configuration_#{suffix}"
      stub_request(:get, "#{BASE_URL}/v1/subscriptions/#{subscription_id}").to_return(
        status: 200,
        body: { data: { id: subscription_id } }.to_json
      )

      client.retrieve_subscription(provider_subscription_id: subscription_id)

      assert_requested(
        :get,
        "#{BASE_URL}/v1/subscriptions/#{subscription_id}",
        headers: { "Authorization" => "Bearer #{api_key}" },
        times: 1
      )
    end
end
