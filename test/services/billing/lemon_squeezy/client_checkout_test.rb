require "test_helper"
require "webmock/minitest"

class Billing::LemonSqueezy::ClientCheckoutTest < ActiveSupport::TestCase
  BASE_URL = "https://api.lemonsqueezy.com"
  API_KEY = "synthetic-checkout-api-key"
  STORE_ID = "100001"
  VARIANT_ID = "200002"
  CHECKOUT_ID = "5e8b546c-c561-4a2c-a586-40c18bb2a195"
  CHECKOUT_HOST = "synthetic-store.lemonsqueezy.test"

  setup do
    @client = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      environment: "test",
      checkout_host: CHECKOUT_HOST,
      env: {},
      credentials: {}
    )
    @expires_at = 20.minutes.from_now.change(usec: 0)
    @return_url = "http://example.com/o/tenant/billing/checkouts/pending"
  end

  test "creates one allowlisted checkout and returns a validated minimal result" do
    captured_body = nil
    stub_request(:post, "#{BASE_URL}/v1/checkouts")
      .with(headers: required_headers)
      .to_return do |request|
        captured_body = JSON.parse(request.body)
        { status: 201, body: valid_response.to_json }
      end

    result = @client.create_checkout(
      variant_id: VARIANT_ID,
      return_url: @return_url,
      expires_at: @expires_at,
      checkout_attempt_token: "signed-checkout-token",
      email_address: " User@Example.Test "
    )

    assert_equal CHECKOUT_ID, result.provider_checkout_id
    assert_equal checkout_url, result.checkout_url
    assert_equal STORE_ID, result.store_id
    assert_equal VARIANT_ID, result.variant_id
    assert result.test_mode
    assert_in_delta @expires_at, result.expires_at, 1.second

    data = captured_body.fetch("data")
    attributes = data.fetch("attributes")
    assert_equal "checkouts", data.fetch("type")
    assert_equal [ VARIANT_ID.to_i ], attributes.dig("product_options", "enabled_variants")
    assert_equal @return_url, attributes.dig("product_options", "redirect_url")
    assert_equal "signed-checkout-token",
      attributes.dig("checkout_data", "custom", "checkout_attempt_token")
    assert_equal "user@example.test", attributes.dig("checkout_data", "email")
    assert_equal true, attributes.fetch("test_mode")
    assert_equal @expires_at.iso8601(6), attributes.fetch("expires_at")
    assert_nil attributes["custom_price"]
    assert_equal STORE_ID, data.dig("relationships", "store", "data", "id")
    assert_equal VARIANT_ID, data.dig("relationships", "variant", "data", "id")
    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: 1
  end

  test "rejects an unsafe provider checkout redirect as an ambiguous invalid response" do
    stub_request(:post, "#{BASE_URL}/v1/checkouts").to_return(
      status: 201,
      body: valid_response(
        "url" => "https://attacker.example/checkout/custom/#{CHECKOUT_ID}?signature=sensitive"
      ).to_json
    )

    error = assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError) do
      create_checkout
    end

    assert_equal 200, error.status
    assert_not_includes error.full_message, "attacker.example"
    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: 1
    assert_not_requested :get, %r{attacker\.example}
  end

  test "rejects mismatched critical checkout response fields" do
    invalid_attributes = [
      { "store_id" => 999_999 },
      { "variant_id" => 999_999 },
      { "test_mode" => false },
      { "expires_at" => 2.hours.from_now.iso8601(6) },
      { "custom_price" => 1 },
      { "product_options" => { "enabled_variants" => [ 999_999 ] } },
      { "product_options" => {} }
    ]

    invalid_attributes.each_with_index do |attributes, index|
      stub_request(:post, "#{BASE_URL}/v1/checkouts").to_return(
        status: 201,
        body: valid_response(attributes).to_json
      )

      assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError, "case #{index}") do
        create_checkout
      end
    end

    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: invalid_attributes.length
  end

  test "requires an explicit null custom price in the provider response" do
    response = valid_response
    response.fetch("data").fetch("attributes").delete("custom_price")
    stub_request(:post, "#{BASE_URL}/v1/checkouts").to_return(
      status: 201,
      body: response.to_json
    )

    assert_raises(Billing::LemonSqueezy::Errors::InvalidResponseError) do
      create_checkout
    end
  end

  test "rejects unsafe local inputs and missing checkout host before network access" do
    unsafe_urls = [
      "https://example.com@attacker.test/return",
      "//attacker.test/return",
      "javascript:alert(1)",
      "http://example.com/return#fragment"
    ]

    unsafe_urls.each do |return_url|
      assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
        create_checkout(return_url: return_url)
      end
    end
    assert_raises(Billing::LemonSqueezy::Errors::RequestError) do
      create_checkout(variant_id: "variant-not-numeric")
    end

    client_without_host = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      environment: "test",
      env: {},
      credentials: {}
    )
    assert_raises(Billing::LemonSqueezy::Errors::ConfigurationError) do
      client_without_host.create_checkout(
        variant_id: VARIANT_ID,
        return_url: @return_url,
        expires_at: @expires_at,
        checkout_attempt_token: "signed-checkout-token"
      )
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "live client sends and requires live test-mode state" do
    live_client = described_class.new(
      api_key: API_KEY,
      store_id: STORE_ID,
      environment: "live",
      checkout_host: CHECKOUT_HOST,
      env: {},
      credentials: {}
    )
    stub_request(:post, "#{BASE_URL}/v1/checkouts").to_return do
      attributes = valid_response.fetch("data").fetch("attributes").merge("test_mode" => false)
      {
        status: 201,
        body: { data: { type: "checkouts", id: CHECKOUT_ID, attributes: attributes } }.to_json
      }
    end

    result = live_client.create_checkout(
      variant_id: VARIANT_ID,
      return_url: "https://example.com/o/tenant/billing/checkouts/pending",
      expires_at: @expires_at,
      checkout_attempt_token: "signed-checkout-token"
    )

    assert_not result.test_mode
    assert_requested :post, "#{BASE_URL}/v1/checkouts", times: 1 do |request|
      JSON.parse(request.body).dig("data", "attributes", "test_mode") == false
    end
  end

  private
    def described_class
      Billing::LemonSqueezy::Client
    end

    def create_checkout(**overrides)
      @client.create_checkout(**{
        variant_id: VARIANT_ID,
        return_url: @return_url,
        expires_at: @expires_at,
        checkout_attempt_token: "signed-checkout-token"
      }.merge(overrides))
    end

    def valid_response(overrides = {})
      attributes = {
        "store_id" => STORE_ID.to_i,
        "variant_id" => VARIANT_ID.to_i,
        "custom_price" => nil,
        "product_options" => { "enabled_variants" => [ VARIANT_ID.to_i ] },
        "expires_at" => @expires_at.iso8601(6),
        "test_mode" => true,
        "url" => checkout_url
      }.merge(overrides)

      {
        "data" => {
          "type" => "checkouts",
          "id" => CHECKOUT_ID,
          "attributes" => attributes
        }
      }
    end

    def checkout_url
      "https://#{CHECKOUT_HOST}/checkout/custom/#{CHECKOUT_ID}?signature=synthetic"
    end

    def required_headers
      {
        "Accept" => "application/vnd.api+json",
        "Authorization" => "Bearer #{API_KEY}",
        "Content-Type" => "application/vnd.api+json"
      }
    end
end
