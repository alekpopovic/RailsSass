require "test_helper"
require "webmock/minitest"
require_relative "../../../support/billing_test_helper"

class Billing::Checkouts::CreateTest < ActiveSupport::TestCase
  include BillingTestHelper

  API_URL = "https://api.lemonsqueezy.com/v1/checkouts"
  API_KEY = "synthetic-create-api-key"
  STORE_ID = "710001"
  PRODUCT_ID = "720002"
  VARIANT_ID = "730003"
  CHECKOUT_HOST = "checkout-service.lemonsqueezy.test"
  CHECKOUT_ID = "7e8b546c-c561-4a2c-a586-40c18bb2a195"

  setup do
    @user = create_test_user(email_address: "checkout-service-#{SecureRandom.hex(4)}@example.test")
    @organization, @membership = create_test_organization_with_owner(
      owner: @user,
      name: "Checkout Service Organization",
      slug: "checkout-service-#{SecureRandom.hex(4)}"
    )
    establish_tenant_context(
      user: @user,
      organization: @organization,
      membership: @membership
    )
    @plan = create_test_plan(name: "Checkout Professional")
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: STORE_ID,
      lemon_product_id: PRODUCT_ID,
      lemon_variant_id: VARIANT_ID
    )
    @mapping = create_billing_provider_price_mapping(
      plan_price: @plan_price,
      environment: "test"
    )
    @client = build_client
  end

  teardown do
    Current.reset
  end

  test "creates attempt and locator atomically then returns a signed provider checkout" do
    captured_token = nil
    captured_return_url = nil
    stub_success do |body|
      captured_token = body.dig("data", "attributes", "checkout_data", "custom", "checkout_attempt_token")
      captured_return_url = body.dig("data", "attributes", "product_options", "redirect_url")
    end
    result = nil
    assert_no_difference -> { Billing::Subscription.count } do
      assert_difference -> { @organization.billing_checkout_attempts.count }, 1 do
        assert_difference -> { @organization.billing_provider_locators.count }, 1 do
          result = create_checkout
        end
      end
    end

    attempt = result.attempt
    locator = @organization.billing_provider_locators.find_by!(billing_checkout_attempt_id: attempt.id)
    payload = Billing::Checkouts::Token.verify(captured_token)

    assert_predicate attempt, :status_ready?
    assert_equal CHECKOUT_ID, attempt.provider_checkout_id
    assert_equal @plan_price.id, attempt.plan_price_id
    assert_equal @membership.id, attempt.initiated_by_membership_id
    assert_predicate attempt, :test_mode?
    assert_predicate locator, :status_unresolved?
    assert_equal Billing::Checkouts::Token.digest_nonce(payload.nonce), attempt.token_digest
    assert_equal @organization.public_id, payload.organization_public_id
    assert_equal @plan_price.id, payload.plan_price_id
    assert_equal @user.id, payload.user_id
    assert_equal attempt.expires_at.to_i, payload.expires_at.to_i
    assert_equal checkout_url, result.checkout_url
    assert_equal Billing::Checkouts::ReturnUrl.call(organization: @organization), captured_return_url
    assert_nil @organization.effective_plan
    assert_not_includes Billing::CheckoutAttempt.column_names, "nonce"
    assert_not_includes Billing::CheckoutAttempt.column_names, "checkout_url"
    assert_requested :post, API_URL, times: 1
  end

  test "double submit reuses pending state without a second provider request" do
    stub_success
    first = create_checkout

    error = assert_raises(Billing::Checkouts::Create::CheckoutPending) do
      create_checkout
    end

    assert_equal first.attempt.id, error.attempt.id
    assert_equal 1, @organization.billing_checkout_attempts.count
    assert_equal 1, @organization.billing_provider_locators.count
    assert_requested :post, API_URL, times: 1
  end

  test "definitive provider rejection fails attempt and resolves its locator" do
    stub_request(:post, API_URL).to_return(
      status: 422,
      body: "sensitive-provider-validation-payload"
    )

    error = assert_raises(Billing::Checkouts::Create::ProviderFailure) do
      create_checkout
    end

    assert_not error.ambiguous?
    attempt = error.attempt.reload
    locator = @organization.billing_provider_locators.find_by!(billing_checkout_attempt_id: attempt.id)
    assert_predicate attempt, :status_failed?
    assert_equal "provider_rejected", attempt.failure_code
    assert_predicate locator, :status_definitive_creation_failure?
    assert locator.resolved_at
    assert_not_includes error.full_message, "sensitive-provider-validation-payload"
    assert_requested :post, API_URL, times: 1
  end

  test "timeout and invalid provider redirect remain creation unknown without retry" do
    stub_request(:post, API_URL).to_timeout
    timeout_error = assert_raises(Billing::Checkouts::Create::ProviderFailure) do
      create_checkout
    end
    timeout_attempt = timeout_error.attempt.reload

    assert timeout_error.ambiguous?
    assert_predicate timeout_attempt, :status_creation_unknown?
    assert_predicate timeout_attempt.provider_locator, :status_unresolved?
    assert_requested :post, API_URL, times: 1

    timeout_attempt.update!(status: :expired, completed_at: Time.current)
    stub_success("url" => "https://attacker.example/checkout/custom/#{CHECKOUT_ID}?signature=secret")
    redirect_error = assert_raises(Billing::Checkouts::Create::ProviderFailure) do
      create_checkout
    end

    assert redirect_error.ambiguous?
    assert_predicate redirect_error.attempt.reload, :status_creation_unknown?
    assert_requested :post, API_URL, times: 2
  end

  test "ambiguous client timeout status and bodyless success retain the pending slot" do
    statuses = [ 408, 429, 204 ]
    statuses.each_with_index do |status, index|
      stub_request(:post, API_URL).to_return(status: status, body: "")

      error = assert_raises(Billing::Checkouts::Create::ProviderFailure) do
        create_checkout
      end

      assert error.ambiguous?
      assert_predicate error.attempt.reload, :status_creation_unknown?
      assert_predicate error.attempt.provider_locator, :status_unresolved?

      next if index == statuses.length - 1

      error.attempt.update!(status: :expired, completed_at: Time.current)
    end

    assert_requested :post, API_URL, times: statuses.length
  end

  test "a conflicting provider checkout identity remains ambiguous instead of returning an error" do
    completed_at = 1.minute.from_now
    create_billing_checkout_attempt(
      organization: @organization,
      membership: @membership,
      plan_price: @plan_price,
      status: :completed,
      provider_checkout_id: CHECKOUT_ID,
      completed_at: completed_at,
      token_consumed_at: completed_at
    )
    stub_success

    error = assert_raises(Billing::Checkouts::Create::ProviderFailure) do
      create_checkout
    end

    assert error.ambiguous?
    assert_predicate error.attempt.reload, :status_creation_unknown?
    assert_predicate error.attempt.provider_locator, :status_unresolved?
    assert_requested :post, API_URL, times: 1
  end

  test "inactive free unmapped and wrong-environment prices are rejected before network access" do
    @plan_price.update!(active: false)
    assert_raises(Billing::Checkouts::Create::InvalidPrice) { create_checkout }

    @plan_price.update!(active: true)
    @mapping.update!(active: false)
    assert_raises(Billing::Checkouts::Create::InvalidPrice) { create_checkout }

    unmapped = create_test_plan_price(
      plan: create_test_plan,
      lemon_store_id: "810001",
      lemon_product_id: "820002",
      lemon_variant_id: "830003"
    )
    assert_raises(Billing::Checkouts::Create::InvalidPrice) do
      create_checkout(plan_price: unmapped)
    end

    free_plan = create_test_plan(free: true, name: "Checkout Free")
    free_price = create_test_plan_price(
      plan: free_plan,
      lemon_store_id: "910001",
      lemon_product_id: "920002",
      lemon_variant_id: "930003"
    )
    create_billing_provider_price_mapping(plan_price: free_price)
    assert_raises(Billing::Checkouts::Create::InvalidPrice) do
      create_checkout(plan_price: free_price)
    end

    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "cross-tenant context and unauthorized organization roles fail server-side" do
    other_user = create_test_user(email_address: "checkout-other-#{SecureRandom.hex(4)}@example.test")
    other_organization, other_membership = create_test_organization_with_owner(
      owner: other_user,
      name: "Other Checkout Organization",
      slug: "other-checkout-#{SecureRandom.hex(4)}"
    )

    assert_raises(Pundit::NotAuthorizedError) do
      described_class.new(
        organization: other_organization,
        user: @user,
        plan_price: @plan_price,
        client: @client
      ).call
    end

    billing_user = create_test_user(email_address: "checkout-member-#{SecureRandom.hex(4)}@example.test")
    ordinary_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :member
    )
    establish_tenant_context(
      user: billing_user,
      organization: @organization,
      membership: ordinary_membership
    )
    assert_raises(Pundit::NotAuthorizedError) do
      described_class.new(
        organization: @organization,
        user: billing_user,
        plan_price: @plan_price,
        client: @client
      ).call
    end

    assert other_membership.active?
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "a current non-expired subscription blocks a second subscription checkout" do
    create_billing_subscription(organization: @organization)

    assert_raises(Billing::Checkouts::Create::ExistingSubscription) do
      create_checkout
    end

    assert_empty @organization.billing_checkout_attempts
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  private
    def described_class
      Billing::Checkouts::Create
    end

    def build_client
      Billing::LemonSqueezy::Client.new(
        api_key: API_KEY,
        store_id: STORE_ID,
        environment: "test",
        checkout_host: CHECKOUT_HOST,
        env: {},
        credentials: {}
      )
    end

    def create_checkout(plan_price: @plan_price)
      described_class.new(
        organization: @organization,
        user: Current.user,
        plan_price: plan_price,
        client: @client
      ).call
    end

    def stub_success(overrides = {})
      stub_request(:post, API_URL).to_return do |request|
        body = JSON.parse(request.body)
        yield body if block_given?
        expires_at = body.dig("data", "attributes", "expires_at")
        attributes = {
          "store_id" => STORE_ID.to_i,
          "variant_id" => VARIANT_ID.to_i,
          "custom_price" => nil,
          "product_options" => { "enabled_variants" => [ VARIANT_ID.to_i ] },
          "expires_at" => expires_at,
          "test_mode" => true,
          "url" => checkout_url
        }.merge(overrides)
        {
          status: 201,
          body: { data: { type: "checkouts", id: CHECKOUT_ID, attributes: attributes } }.to_json
        }
      end
    end

    def checkout_url
      "https://#{CHECKOUT_HOST}/checkout/custom/#{CHECKOUT_ID}?signature=synthetic"
    end
end
