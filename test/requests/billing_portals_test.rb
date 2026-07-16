require "test_helper"
require_relative "../support/billing_test_helper"

class BillingPortalsRequestTest < ActionDispatch::IntegrationTest
  include BillingTestHelper

  BASE_URL = "https://api.lemonsqueezy.com"
  PORTAL_HOST = "request-portal.lemonsqueezy.test"

  setup do
    suffix = SecureRandom.hex(5)
    @store_id = unique_numeric_id
    @customer_id = unique_numeric_id
    @product_id = unique_numeric_id
    @variant_id = unique_numeric_id
    @subscription_id = unique_numeric_id
    @owner = create_test_user(email_address: "portal-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Portal Request Organization",
      slug: "portal-request-#{suffix}"
    )
    create_locator_for(@owner_membership)
    @plan = create_test_plan(name: "Portal Professional", position: 20)
    @plan_price = create_test_plan_price(
      plan: @plan,
      lemon_store_id: @store_id,
      lemon_product_id: @product_id,
      lemon_variant_id: @variant_id
    )
    @customer = create_billing_customer(
      organization: @organization,
      provider_customer_id: @customer_id
    )
    @subscription = create_billing_subscription(
      organization: @organization,
      billing_customer: @customer,
      plan_price: @plan_price,
      provider_subscription_id: @subscription_id,
      provider_customer_id: @customer_id
    )
    sign_in_as(@owner)
  end

  test "owner and billing may open the portal while admin and member are denied" do
    signed_url = portal_url
    stub_portal_success(urls: [ signed_url, signed_url ])

    with_lemon_configuration { post_portal }
    assert_response :see_other
    assert_equal signed_url, response.location

    delete session_path
    sign_in_role(:billing)
    with_lemon_configuration { post_portal }
    assert_response :see_other
    assert_equal signed_url, response.location

    %i[admin member].each do |role|
      delete session_path
      sign_in_role(role)

      with_lemon_configuration { post_portal }
      assert_response :forbidden
    end

    assert_requested :get, subscription_url, times: 2
  end

  test "every click fetches a fresh portal URL without changing local billing authority" do
    first_url = portal_url(signature: "a" * 64)
    second_url = portal_url(signature: "b" * 64)
    stub_portal_success(urls: [ first_url, second_url ])
    subscription_before = @subscription.reload.attributes
    customer_before = @customer.reload.attributes
    effective_plan_before = effective_plan_id

    assert_no_difference -> { Billing::PlanChange.count } do
      with_lemon_configuration { post_portal }
      assert_equal first_url, response.location

      with_lemon_configuration { post_portal }
      assert_equal second_url, response.location
    end

    assert_equal subscription_before, @subscription.reload.attributes
    assert_equal customer_before, @customer.reload.attributes
    assert_equal effective_plan_before, effective_plan_id
    assert_equal @plan.id, effective_plan_before
    persisted_billing = [ @subscription.attributes, @customer.attributes ].to_json
    assert_not_includes persisted_billing, first_url
    assert_not_includes persisted_billing, second_url
    assert_requested :get, subscription_url, times: 2
  end

  test "provider failures return a safe internal redirect without leaking response data" do
    sensitive_payload = "SENSITIVE_PORTAL_PROVIDER_PAYLOAD"
    stub_request(:get, subscription_url).to_return(
      status: 503,
      body: sensitive_payload
    )
    subscription_before = @subscription.reload.attributes

    with_lemon_configuration { post_portal }

    assert_redirected_to organization_billing_path(organization_slug: @organization.slug)
    assert_not_includes response.location, sensitive_payload
    follow_redirect!
    assert_response :success
    assert_match(/temporarily unavailable/i, response.body)
    assert_not_includes response.body, sensitive_payload
    assert_equal subscription_before, @subscription.reload.attributes
    assert_requested :get, subscription_url, times: 1
  end

  test "a foreign tenant route is not found before provider access" do
    other_owner = create_test_user(
      email_address: "portal-foreign-owner-#{SecureRandom.hex(5)}@example.test"
    )
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Foreign Portal Organization",
      slug: "foreign-portal-#{SecureRandom.hex(5)}"
    )

    with_lemon_configuration do
      post organization_billing_portal_path(organization_slug: other_organization.slug)
    end

    assert_response :not_found
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "the signed portal URL is not written to application logs" do
    signed_url = portal_url(signature: "c" * 64)
    stub_portal_success(urls: [ signed_url ])
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    original_rails_logger = Rails.logger
    original_controller_logger = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger

    with_lemon_configuration { post_portal }

    assert_response :see_other
    assert_equal signed_url, response.location
    assert_not_includes output.string, signed_url
    assert_not_includes output.string, URI.parse(signed_url).query
  ensure
    Rails.logger = original_rails_logger if original_rails_logger
    ActionController::Base.logger = original_controller_logger if original_controller_logger
  end

  private
    def post_portal
      post organization_billing_portal_path(organization_slug: @organization.slug)
    end

    def sign_in_role(role)
      user = create_test_user(
        email_address: "portal-#{role}-#{SecureRandom.hex(5)}@example.test"
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

    def with_lemon_configuration
      values = {
        "LEMON_SQUEEZY_API_KEY" => "synthetic-portal-request-key",
        "LEMON_SQUEEZY_STORE_ID" => @store_id,
        "LEMON_SQUEEZY_ENVIRONMENT" => "test",
        "LEMON_SQUEEZY_CHECKOUT_HOST" => PORTAL_HOST
      }
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous&.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    def stub_portal_success(urls: [ portal_url ])
      responses = urls.map do |url|
        {
          status: 200,
          body: {
            data: {
              type: "subscriptions",
              id: @subscription_id,
              attributes: {
                store_id: @store_id.to_i,
                customer_id: @customer_id.to_i,
                test_mode: true,
                urls: { customer_portal: url }
              }
            }
          }.to_json
        }
      end
      stub_request(:get, subscription_url).to_return(*responses)
    end

    def portal_url(signature: "a" * 64)
      query = URI.encode_www_form(
        expires: 2.hours.from_now.to_i,
        user: @customer_id,
        signature: signature
      )
      "https://#{PORTAL_HOST}/billing?#{query}"
    end

    def subscription_url
      "#{BASE_URL}/v1/subscriptions/#{@subscription_id}"
    end

    def effective_plan_id
      Current.set(organization: @organization) do
        @organization.effective_plan&.id
      end
    end

    def unique_numeric_id
      SecureRandom.random_number(8_999_999_999).then { |value| (value + 1_000_000_000).to_s }
    end
end
