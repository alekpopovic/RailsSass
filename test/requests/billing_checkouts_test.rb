require "test_helper"
require "webmock/minitest"
require_relative "../support/billing_test_helper"

class BillingCheckoutsRequestTest < ActionDispatch::IntegrationTest
  include BillingTestHelper

  API_URL = "https://api.lemonsqueezy.com/v1/checkouts"
  STORE_ID = "610001"
  PRODUCT_ID = "620002"
  VARIANT_ID = "630003"
  CHECKOUT_ID = "6e8b546c-c561-4a2c-a586-40c18bb2a195"
  CHECKOUT_HOST = "request-checkout.lemonsqueezy.test"

  setup do
    @original_configured_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    Rails.configuration.x.billing.lemon_squeezy.store_id = STORE_ID
    suffix = SecureRandom.hex(4)
    @owner = create_test_user(email_address: "checkout-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Checkout Request Organization",
      slug: "checkout-request-#{suffix}"
    )
    create_locator_for(@owner_membership)
    @plan = create_test_plan(name: "Request Professional")
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: STORE_ID,
      lemon_product_id: PRODUCT_ID,
      lemon_variant_id: VARIANT_ID
    )
    @mapping = create_billing_provider_price_mapping(plan_price: @plan_price)
    sign_in_as(@owner)
  end

  teardown do
    Rails.configuration.x.billing.lemon_squeezy.store_id = @original_configured_store_id
  end

  test "owner and billing member can start checkout while admin and member are denied" do
    stub_success
    post_with_client
    assert_response :see_other
    assert_equal checkout_url, response.location

    delete session_path
    @organization.billing_checkout_attempts.first.update!(
      status: :expired,
      completed_at: Time.current
    )

    billing_user, = sign_in_role(:billing)
    stub_success(checkout_id: "8e8b546c-c561-4a2c-a586-40c18bb2a195")
    post_with_client
    assert_response :see_other
    assert_equal 2, @organization.billing_checkout_attempts.count

    [ :admin, :member ].each do |role|
      delete session_path
      sign_in_role(role)

      assert_no_difference -> { @organization.billing_checkout_attempts.count } do
        post_with_client
      end
      assert_response :forbidden
    end

    assert billing_user.persisted?
    assert_requested :post, API_URL, times: 2
  end

  test "pricing renders server-owned checkout CTA only to billing-authorized roles" do
    get organization_pricing_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "form[action=?]",
      organization_billing_checkouts_path(organization_slug: @organization.slug), count: 1
    assert_select "input[name='plan_price_id'][value=?]", @plan_price.id.to_s
    assert_match "Test mode — no real charge", response.body

    delete session_path
    sign_in_role(:member)
    get organization_pricing_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "form[action=?]",
      organization_billing_checkouts_path(organization_slug: @organization.slug), count: 0
    assert_match(/owner or billing member/i, response.body)
  end

  test "double submit creates one provider checkout and redirects the second request to pending" do
    stub_success

    assert_difference -> { @organization.billing_checkout_attempts.count }, 1 do
      post_with_client
      assert_response :see_other
      assert_equal checkout_url, response.location

      post_with_client
      assert_redirected_to organization_billing_checkout_pending_path(
        organization_slug: @organization.slug
      )
    end

    assert_equal 1, @organization.billing_provider_locators.count
    assert_requested :post, API_URL, times: 1

    get organization_pricing_path(organization_slug: @organization.slug)
    assert_select "form[action=?]",
      organization_billing_checkouts_path(organization_slug: @organization.slug), count: 0
    assert_select "a[href=?]", organization_billing_checkout_pending_path(
      organization_slug: @organization.slug
    ), text: "View pending checkout"
  end

  test "checkout audit captures the current request ID without leaking the previous request" do
    first_request_id = "checkout-request-first-#{SecureRandom.hex(5)}"
    second_request_id = "checkout-request-second-#{SecureRandom.hex(5)}"
    stub_success

    post_with_client(headers: { "X-Request-Id" => first_request_id })

    first_event = @organization.audit_events
      .where(action: "billing.checkout.started")
      .order(:id)
      .last
    assert_equal first_request_id, first_event.request_id

    @organization.billing_checkout_attempts
      .find(first_event.subject_id)
      .update!(status: :expired, completed_at: Time.current)
    stub_success(checkout_id: "9e8b546c-c561-4a2c-a586-40c18bb2a195")

    post_with_client(headers: { "X-Request-Id" => second_request_id })

    events = @organization.audit_events
      .where(action: "billing.checkout.started")
      .order(:id)
      .last(2)
    assert_equal [ first_request_id, second_request_id ], events.map(&:request_id)
  end

  test "provider return page remains pending and never changes subscription or entitlement" do
    stub_success
    assert_no_difference -> { Billing::Subscription.count } do
      post_with_client
      assert_response :see_other

      get organization_billing_checkout_pending_path(
        organization_slug: @organization.slug,
        provider_subscription_id: "attacker-controlled",
        status: "active",
        plan_price_id: @plan_price.id
      )
    end

    assert_response :success
    assert_select "[role='status'][aria-live='polite']"
    assert_match "Payment confirmation pending", response.body
    assert_match "Waiting for verified payment confirmation", response.body
    assert_match "Test mode", response.body
    assert_no_match(/attacker-controlled|provider_checkout_id|token_digest/, response.body)
    Current.set(organization: @organization) do
      assert_nil @organization.effective_plan
    end
    assert_nil @organization.billing_subscriptions.find_by(current: true)
  end

  test "unsafe provider redirect is never followed and leaves an ambiguous pending attempt" do
    stub_success(
      url: "https://attacker.example/checkout/custom/#{CHECKOUT_ID}?signature=sensitive"
    )

    post_with_client

    assert_redirected_to organization_billing_checkout_pending_path(
      organization_slug: @organization.slug
    )
    follow_redirect!
    assert_response :success
    assert_match(/could not be confirmed/i, response.body)
    assert_predicate @organization.billing_checkout_attempts.last, :status_creation_unknown?
    assert_not_requested :get, %r{attacker\.example}
    assert_requested :post, API_URL, times: 1
  end

  test "provider errors are generic and do not expose provider payloads" do
    stub_request(:post, API_URL).to_return(
      status: 422,
      body: "SENSITIVE_PROVIDER_PAYLOAD_SENTINEL"
    )

    post_with_client

    assert_redirected_to organization_pricing_path(organization_slug: @organization.slug)
    follow_redirect!
    assert_response :success
    assert_match(/temporarily unavailable/i, response.body)
    assert_no_match(/SENSITIVE_PROVIDER_PAYLOAD_SENTINEL/, response.body)
    assert_predicate @organization.billing_checkout_attempts.last, :status_failed?
  end

  test "signed correlation and provider checkout URLs are not written to application logs" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    original_rails_logger = Rails.logger
    original_controller_logger = ActionController::Base.logger
    captured_token = nil
    Rails.logger = logger
    ActionController::Base.logger = logger
    stub_success do |body|
      captured_token = body.dig(
        "data", "attributes", "checkout_data", "custom", "checkout_attempt_token"
      )
    end

    post_with_client

    assert_response :see_other
    assert_predicate captured_token, :present?
    assert_not_includes output.string, captured_token
    assert_not_includes output.string, checkout_url
  ensure
    Rails.logger = original_rails_logger if original_rails_logger
    ActionController::Base.logger = original_controller_logger if original_controller_logger
  end

  test "inactive or unmapped prices and another tenant slug are rejected before provider access" do
    @plan_price.update!(active: false)
    assert_no_difference -> { @organization.billing_checkout_attempts.count } do
      post_with_client
    end
    assert_redirected_to organization_pricing_path(organization_slug: @organization.slug)

    other_owner = create_test_user(email_address: "checkout-other-owner-#{SecureRandom.hex(4)}@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Checkout Tenant",
      slug: "other-checkout-tenant-#{SecureRandom.hex(4)}"
    )
    post organization_billing_checkouts_path(organization_slug: other_organization.slug),
      params: { plan_price_id: @plan_price.id }

    assert_response :not_found
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "checkout POST remains protected by Rails CSRF" do
    original_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference -> { @organization.billing_checkout_attempts.count } do
      post organization_billing_checkouts_path(organization_slug: @organization.slug),
        params: { plan_price_id: @plan_price.id }
    end

    assert_response :unprocessable_content
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  ensure
    ActionController::Base.allow_forgery_protection = original_setting
  end

  private
    def post_with_client(headers: {})
      with_lemon_configuration do
        post organization_billing_checkouts_path(organization_slug: @organization.slug),
          params: { plan_price_id: @plan_price.id },
          headers: headers
      end
    end

    def with_lemon_configuration
      values = {
        "LEMON_SQUEEZY_API_KEY" => "synthetic-request-key",
        "LEMON_SQUEEZY_STORE_ID" => STORE_ID,
        "LEMON_SQUEEZY_ENVIRONMENT" => "test",
        "LEMON_SQUEEZY_CHECKOUT_HOST" => CHECKOUT_HOST
      }
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous&.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    def sign_in_role(role)
      user = create_test_user(
        email_address: "checkout-#{role}-#{SecureRandom.hex(4)}@example.test"
      )
      membership = create_test_membership(
        organization: @organization,
        user: user,
        role: role
      )
      create_locator_for(membership)
      sign_in_as(user)
      [ user, membership ]
    end

    def create_locator_for(membership)
      OrganizationAccessLocator.find_or_create_by!(
        organization_membership: membership,
        organization: membership.organization,
        user: membership.user
      )
    end

    def stub_success(url: checkout_url, checkout_id: CHECKOUT_ID)
      stub_request(:post, API_URL).to_return do |request|
        body = JSON.parse(request.body)
        yield body if block_given?
        expires_at = body.dig("data", "attributes", "expires_at")
        {
          status: 201,
          body: {
            data: {
              type: "checkouts",
              id: checkout_id,
              attributes: {
                store_id: STORE_ID.to_i,
                variant_id: VARIANT_ID.to_i,
                custom_price: nil,
                product_options: { enabled_variants: [ VARIANT_ID.to_i ] },
                expires_at: expires_at,
                test_mode: true,
                url: url.sub(CHECKOUT_ID, checkout_id)
              }
            }
          }.to_json
        }
      end
    end

    def checkout_url
      "https://#{CHECKOUT_HOST}/checkout/custom/#{CHECKOUT_ID}?signature=synthetic"
    end
end
