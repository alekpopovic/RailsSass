require "test_helper"
require "webmock/minitest"

class Billing::LemonSqueezy::ClientManagementTest < ActiveSupport::TestCase
  BASE_URL = "https://api.lemonsqueezy.com"
  API_KEY = "synthetic-management-api-key"
  STORE_ID = "61001"
  CUSTOMER_ID = "62002"
  PRODUCT_ID = "63003"
  CURRENT_VARIANT_ID = "64004"
  TARGET_VARIANT_ID = "64005"
  SUBSCRIPTION_ID = "65006"
  PORTAL_HOST = "synthetic-store.lemonsqueezy.test"

  setup do
    @client = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      environment: "test",
      checkout_host: PORTAL_HOST,
      env: {},
      credentials: {}
    )
    @created_at = 1.day.ago.change(usec: 0)
    @updated_at = 1.hour.ago.change(usec: 0)
  end

  test "fetches and returns a freshly validated signed customer portal URL" do
    first_url = portal_url(signature: "a" * 64)
    second_url = portal_url(signature: "b" * 64)
    stub_request(:get, subscription_url).with(headers: required_headers).to_return(
      { status: 200, body: valid_subscription_payload(portal_url: first_url).to_json },
      { status: 200, body: valid_subscription_payload(portal_url: second_url).to_json }
    )

    returned_urls = nil
    assert_no_difference -> { Billing::Subscription.count } do
      returned_urls = 2.times.map do
        @client.retrieve_customer_portal_url(
          provider_subscription_id: SUBSCRIPTION_ID,
          expected_customer_id: CUSTOMER_ID
        )
      end
    end

    assert_equal [ first_url, second_url ], returned_urls
    assert_requested :get, subscription_url, headers: required_headers, times: 2
    assert_not_includes @client.inspect, first_url
    assert_not_includes @client.inspect, second_url
  end

  test "rejects unsafe expired or malformed portal URLs without following them" do
    unsafe_urls = [
      "http://#{PORTAL_HOST}/billing?#{portal_query}",
      "https://attacker.example/billing?#{portal_query}",
      "https://#{PORTAL_HOST}@attacker.example/billing?#{portal_query}",
      "https://#{PORTAL_HOST}/billing?#{portal_query}#fragment",
      "https://#{PORTAL_HOST}/not-billing?#{portal_query}",
      "https://#{PORTAL_HOST}/billing",
      portal_url(expires_at: 1.second.ago.to_i),
      portal_url(expires_at: 1.hour.ago.to_i),
      "#{portal_url}&signature=#{'b' * 64}",
      "#{portal_url}&user=%0A"
    ]

    unsafe_urls.each_with_index do |unsafe_url, index|
      subscription_id = "unsafe_#{index}"
      stub_request(:get, "#{BASE_URL}/v1/subscriptions/#{subscription_id}").to_return(
        status: 200,
        body: valid_subscription_payload(
          subscription_id: subscription_id,
          portal_url: unsafe_url
        ).to_json
      )

      error = assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError) do
        @client.retrieve_customer_portal_url(
          provider_subscription_id: subscription_id,
          expected_customer_id: CUSTOMER_ID
        )
      end

      assert_equal 200, error.status
      assert_not_includes error.full_message, unsafe_url
    end

    assert_not_requested :get, %r{attacker\.example}
  end

  test "rejects portal responses whose provider identity does not match local authority" do
    mismatches = [
      ->(payload) { payload["data"]["type"] = "customers" },
      ->(payload) { payload["data"]["id"] = "different_subscription" },
      ->(payload) { payload["data"]["attributes"]["store_id"] = 99_999 },
      ->(payload) { payload["data"]["attributes"]["customer_id"] = 99_999 },
      ->(payload) { payload["data"]["attributes"]["test_mode"] = false },
      ->(payload) { payload["data"]["attributes"]["urls"] = {} }
    ]

    mismatches.each_with_index do |mutate, index|
      subscription_id = "identity_#{index}"
      payload = valid_subscription_payload(subscription_id: subscription_id)
      mutate.call(payload)
      stub_request(:get, "#{BASE_URL}/v1/subscriptions/#{subscription_id}").to_return(
        status: 200,
        body: payload.to_json
      )

      assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError) do
        @client.retrieve_customer_portal_url(
          provider_subscription_id: subscription_id,
          expected_customer_id: CUSTOMER_ID
        )
      end
    end
  end

  test "requires the configured customer-facing host before requesting a portal URL" do
    client = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      environment: "test",
      env: {},
      credentials: {}
    )

    assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      client.retrieve_customer_portal_url(
        provider_subscription_id: SUBSCRIPTION_ID,
        expected_customer_id: CUSTOMER_ID
      )
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "patches only the requested variant and returns a strict subscription snapshot" do
    captured_body = nil
    stub_request(:patch, subscription_url)
      .with(headers: required_headers)
      .to_return do |request|
        captured_body = JSON.parse(request.body)
        {
          status: 200,
          body: valid_subscription_payload(variant_id: TARGET_VARIANT_ID).to_json
        }
      end

    snapshot = nil
    assert_no_difference -> { Billing::Subscription.count } do
      snapshot = @client.update_subscription_variant(
        provider_subscription_id: SUBSCRIPTION_ID,
        variant_id: TARGET_VARIANT_ID
      )
    end

    assert_equal TARGET_VARIANT_ID, snapshot.provider_variant_id
    assert_equal PRODUCT_ID, snapshot.provider_product_id
    assert_equal CUSTOMER_ID, snapshot.provider_customer_id
    assert_equal @updated_at.to_i, snapshot.provider_updated_at.to_i
    assert_equal({
      "data" => {
        "type" => "subscriptions",
        "id" => SUBSCRIPTION_ID,
        "attributes" => { "variant_id" => TARGET_VARIANT_ID.to_i }
      }
    }, captured_body)
    assert_requested :patch, subscription_url, headers: required_headers, times: 1
  end

  test "distinguishes a mismatched target variant from an unknown status response" do
    cases = {
      valid_subscription_payload(variant_id: CURRENT_VARIANT_ID) =>
        Billing::LemonSqueezy::Errors::VariantMismatchError,
      valid_subscription_payload(variant_id: TARGET_VARIANT_ID, status: "future_status") =>
        Billing::LemonSqueezy::Errors::InvalidResponseError
    }
    stub_request(:patch, subscription_url).to_return(*cases.map { |payload, _error_class|
      { status: 200, body: payload.to_json }
    })

    cases.each_value do |error_class|
      assert_raises(error_class) do
        @client.update_subscription_variant(
          provider_subscription_id: SUBSCRIPTION_ID,
          variant_id: TARGET_VARIANT_ID
        )
      end
    end

    assert_requested :patch, subscription_url, times: cases.length
  end

  test "maps an update timeout without blindly retrying the patch" do
    stub_request(:patch, subscription_url).to_timeout

    error = assert_raises(Billing::LemonSqueezy::Errors::TimeoutError) do
      @client.update_subscription_variant(
        provider_subscription_id: SUBSCRIPTION_ID,
        variant_id: TARGET_VARIANT_ID
      )
    end

    assert_predicate error, :retryable?
    assert_requested :patch, subscription_url, times: 1
  end

  test "rejects unsafe management identifiers before network access" do
    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      @client.retrieve_customer_portal_url(
        provider_subscription_id: "../other",
        expected_customer_id: CUSTOMER_ID
      )
    end
    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      @client.retrieve_customer_portal_url(
        provider_subscription_id: SUBSCRIPTION_ID,
        expected_customer_id: "not-numeric"
      )
    end
    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      @client.update_subscription_variant(
        provider_subscription_id: SUBSCRIPTION_ID,
        variant_id: "../variant"
      )
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  private
    def described_class
      Billing::LemonSqueezy::Client
    end

    def subscription_url
      "#{BASE_URL}/v1/subscriptions/#{SUBSCRIPTION_ID}"
    end

    def portal_url(signature: "a" * 64, expires_at: 2.hours.from_now.to_i)
      "https://#{PORTAL_HOST}/billing?#{portal_query(signature: signature, expires_at: expires_at)}"
    end

    def portal_query(signature: "a" * 64, expires_at: 2.hours.from_now.to_i)
      URI.encode_www_form(expires: expires_at, user: CUSTOMER_ID, signature: signature)
    end

    def valid_subscription_payload(
      subscription_id: SUBSCRIPTION_ID,
      variant_id: CURRENT_VARIANT_ID,
      status: "active",
      portal_url: self.portal_url
    )
      {
        "data" => {
          "type" => "subscriptions",
          "id" => subscription_id,
          "attributes" => {
            "store_id" => STORE_ID.to_i,
            "customer_id" => CUSTOMER_ID.to_i,
            "product_id" => PRODUCT_ID.to_i,
            "variant_id" => variant_id.to_i,
            "status" => status,
            "card_brand" => "visa",
            "card_last_four" => "4242",
            "pause" => nil,
            "trial_ends_at" => nil,
            "renews_at" => 30.days.from_now.iso8601(6),
            "ends_at" => nil,
            "created_at" => @created_at.iso8601(6),
            "updated_at" => @updated_at.iso8601(6),
            "test_mode" => true,
            "urls" => { "customer_portal" => portal_url }
          }
        }
      }
    end

    def required_headers
      {
        "Accept" => "application/vnd.api+json",
        "Authorization" => "Bearer #{API_KEY}",
        "Content-Type" => "application/vnd.api+json"
      }
    end
end
