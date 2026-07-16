require "test_helper"
require "webmock/minitest"
require_relative "../support/billing_test_helper"

class BillingManagementRequestTest < ActionDispatch::IntegrationTest
  include BillingTestHelper

  BASE_URL = "https://api.lemonsqueezy.com"
  STORE_ID = "71001"
  CUSTOMER_ID = "72002"
  SOURCE_PRODUCT_ID = "73003"
  SOURCE_VARIANT_ID = "74004"
  UPGRADE_PRODUCT_ID = "73005"
  UPGRADE_VARIANT_ID = "74006"
  DOWNGRADE_PRODUCT_ID = "73007"
  DOWNGRADE_VARIANT_ID = "74008"
  YEARLY_PRODUCT_ID = "73009"
  YEARLY_VARIANT_ID = "74010"
  SUBSCRIPTION_ID = "75011"

  setup do
    configure_lemon_environment
    suffix = SecureRandom.hex(5)
    @owner = create_test_user(
      name: "Billing owner",
      email_address: "billing-management-owner-#{suffix}@example.test"
    )
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Billing management #{suffix}",
      slug: "billing-management-#{suffix}"
    )
    create_locator_for(@owner_membership)
    create_catalog
    create_subscription
    sign_in_as(@owner)
  end

  teardown do
    restore_lemon_environment
    Current.reset
  end

  test "owner and billing members can manage billing while other organization roles are denied" do
    get billing_path

    assert_response :success
    assert_select "form[action=?]", plan_changes_path

    delete session_path
    billing_user, = sign_in_role(:billing)
    get billing_path
    assert_response :success

    stub_variant_update(@upgrade_price)
    assert_difference -> { @organization.billing_plan_changes.count }, 1 do
      post plan_changes_path, params: { plan_price_id: @upgrade_price.id }
    end
    assert_response :see_other
    assert_predicate @organization.billing_plan_changes.last, :status_submitted?

    %i[admin member].each do |role|
      delete session_path
      sign_in_role(role)

      get billing_path
      assert_response :forbidden

      assert_no_difference -> { @organization.billing_plan_changes.count } do
        post plan_changes_path, params: { plan_price_id: @downgrade_price.id }
      end
      assert_response :forbidden
    end

    assert billing_user.persisted?
    assert_requested :patch, subscription_url, times: 1
  end

  test "a foreign organization route is not billing authority" do
    foreign_owner = create_test_user(
      email_address: "billing-management-foreign-#{SecureRandom.hex(5)}@example.test"
    )
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Billing Management",
      slug: "foreign-billing-management-#{SecureRandom.hex(5)}"
    )

    assert_no_difference -> { Billing::PlanChange.count } do
      post organization_billing_plan_changes_path(
        organization_slug: foreign_organization.slug
      ), params: { plan_price_id: @upgrade_price.id }
    end

    assert_response :not_found
    assert_not_requested :patch, subscription_url
  end

  test "billing overview renders local plan lifecycle payment and warning details" do
    trial_ends_at = 7.days.from_now.change(usec: 0)
    @subscription.update!(
      status: :on_trial,
      trial_ends_at: trial_ends_at,
      renews_at: 30.days.from_now.change(usec: 0)
    )

    get billing_path

    assert_response :success
    assert_select "h1", "Billing overview"
    assert_match @source_plan.name, response.body
    assert_match "Monthly", response.body
    assert_match "EUR", response.body
    assert_match "On trial", response.body
    assert_match I18n.l(trial_ends_at, format: :long), response.body
    assert_match "Visa ending in 4242", response.body
    assert_select "span", text: "Test mode", count: 1
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}

    @subscription.update!(
      status: :past_due,
      trial_ends_at: nil,
      past_due_started_at: @subscription.provider_updated_at - 1.minute
    )
    get billing_path
    assert_select "[role='alert']", text: /Payment is past due/

    @subscription.update!(
      status: :cancelled,
      past_due_started_at: nil,
      ends_at: 10.days.from_now.change(usec: 0)
    )
    get billing_path
    assert_select "[role='alert']", text: /subscription is cancelled/
    assert_select "dt", text: "Ends"

    @subscription.update!(status: :unpaid, ends_at: nil)
    get billing_path
    assert_select "[role='alert']", text: /subscription is unpaid/
  end

  test "billing overview reports current over-limit usage through the tenant product boundary" do
    @source_limit_entitlement.update!(limit_value: 1)
    create_reports(2)

    get billing_path

    assert_response :success
    assert_select "[role='alert']", text: /Current usage is over a plan limit/
    assert_match "2 reports used, 1 allowed", response.body
  end

  test "test-mode labeling is suppressed when rendering as production" do
    original_environment = Rails.env
    Rails.singleton_class.define_method(:env) do
      ActiveSupport::EnvironmentInquirer.new("production")
    end
    get billing_path

    assert_response :success
    assert_select "span", text: "Test mode", count: 0
  ensure
    Rails.singleton_class.define_method(:env) { original_environment }
  end

  test "plan options use capability classifications for upgrade downgrade and interval changes" do
    get billing_path

    assert_response :success
    assert_select "article", text: /Upgrade.*#{Regexp.escape(@upgrade_plan.name)}/m
    assert_select "article", text: /Downgrade.*#{Regexp.escape(@downgrade_plan.name)}/m
    assert_select "article", text: /Billing interval change.*#{Regexp.escape(@source_plan.name)}/m
    assert_select "form[action=?]", plan_changes_path, minimum: 3
    assert_select "button", text: "Request upgrade"
    assert_select "button", text: "Request downgrade"
    assert_select "button", text: "Request billing interval change"
    assert_not_requested :any, %r{api\.lemonsqueezy\.com}
  end

  test "a successful plan change remains pending locally and duplicate submit does not patch twice" do
    stub_variant_update(@upgrade_price)

    assert_difference -> { @organization.billing_plan_changes.count }, 1 do
      post plan_changes_path, params: { plan_price_id: @upgrade_price.id }
    end

    assert_redirected_to billing_path
    change = @organization.billing_plan_changes.last
    assert_predicate change, :status_submitted?
    assert_equal @source_price, @subscription.reload.plan_price
    assert_equal @source_plan, effective_plan

    follow_redirect!
    assert_response :success
    assert_match @source_plan.name, response.body
    assert_match "awaiting provider confirmation", response.body
    assert_match @upgrade_plan.name, response.body
    assert_match(/current effective plan does not change/i, response.body)

    assert_no_difference -> { @organization.billing_plan_changes.count } do
      post plan_changes_path, params: { plan_price_id: @upgrade_price.id }
    end
    assert_redirected_to billing_path
    follow_redirect!
    assert_match(/already pending provider confirmation/i, response.body)
    assert_equal @source_plan, effective_plan
    assert_requested :patch, subscription_url, times: 1
  end

  test "an incompatible downgrade is blocked in both UI and direct request" do
    create_reports(3)

    get billing_path

    assert_response :success
    assert_select "article", text: /#{Regexp.escape(@downgrade_plan.name)}.*not currently compatible/m
    assert_select "form[action=?] input[value=?]", plan_changes_path, @downgrade_price.id.to_s, count: 0

    assert_no_difference -> { @organization.billing_plan_changes.count } do
      post plan_changes_path, params: { plan_price_id: @downgrade_price.id }
    end
    assert_redirected_to billing_path
    follow_redirect!
    assert_match(/blocked because current usage exceeds/i, response.body)
    assert_equal @source_plan, effective_plan
    assert_not_requested :patch, subscription_url
  end

  test "a provider timeout has safe ambiguous UX and remains idempotently pending" do
    stub_request(:patch, subscription_url).to_timeout

    post plan_changes_path, params: { plan_price_id: @upgrade_price.id }

    assert_redirected_to billing_path
    change = @organization.billing_plan_changes.last
    assert_predicate change, :status_creation_unknown?
    assert_equal @source_plan, effective_plan
    follow_redirect!
    assert_match(/provider result is not yet known/i, response.body)
    assert_no_match(/Faraday|TimeoutError|api\.lemonsqueezy/i, response.body)

    assert_no_difference -> { @organization.billing_plan_changes.count } do
      post plan_changes_path, params: { plan_price_id: @upgrade_price.id }
    end
    assert_redirected_to billing_path
    assert_requested :patch, subscription_url, times: 1
  end

  test "a mismatched provider variant response fails safely" do
    stub_variant_update(@upgrade_price, variant_id: SOURCE_VARIANT_ID)

    post plan_changes_path, params: { plan_price_id: @upgrade_price.id }

    assert_redirected_to billing_path
    change = @organization.billing_plan_changes.last
    assert_predicate change, :status_failed?
    assert_equal "provider_variant_mismatch", change.failure_code
    assert_equal @source_price, @subscription.reload.plan_price
    assert_equal @source_plan, effective_plan
    follow_redirect!
    assert_match(/provider rejected the plan change/i, response.body)
    assert_no_match(/#{SOURCE_VARIANT_ID}|InvalidResponseError|raw_payload/i, response.body)
    assert_requested :patch, subscription_url, times: 1
  end

  test "a mismatched provider product response fails safely without changing the local plan" do
    stub_variant_update(@upgrade_price, product_id: "99999")

    post plan_changes_path, params: { plan_price_id: @upgrade_price.id }

    assert_redirected_to billing_path
    change = @organization.billing_plan_changes.last
    assert_predicate change, :status_failed?
    assert_equal "provider_variant_mismatch", change.failure_code
    assert_equal @source_price, @subscription.reload.plan_price
    assert_equal @source_plan, effective_plan
    follow_redirect!
    assert_match(/provider rejected the plan change/i, response.body)
    assert_no_match(/99999|provider_variant_mismatch|raw_payload/i, response.body)
    assert_requested :patch, subscription_url, times: 1
  end

  private
    def billing_path
      organization_billing_path(organization_slug: @organization.slug)
    end

    def plan_changes_path
      organization_billing_plan_changes_path(organization_slug: @organization.slug)
    end

    def subscription_url
      "#{BASE_URL}/v1/subscriptions/#{SUBSCRIPTION_ID}"
    end

    def create_catalog
      @analytics = create_test_product(key: "analytics", name: "Analytics")
      @report_limit = create_test_product_feature(
        product: @analytics,
        key: "report_limit",
        name: "Report limit",
        kind: :limit
      )
      @dashboards = create_test_product_feature(
        product: @analytics,
        key: "dashboards",
        name: "Dashboards"
      )
      @csv_export = create_test_product_feature(
        product: @analytics,
        key: "csv_export",
        name: "CSV export"
      )

      @source_plan = create_test_plan(name: "Current Professional", position: 90)
      source_plan_product = create_test_plan_product(plan: @source_plan, product: @analytics)
      @source_limit_entitlement = create_test_entitlement(
        plan_product: source_plan_product,
        product_feature: @report_limit,
        limit_value: 5
      )
      create_test_entitlement(
        plan_product: source_plan_product,
        product_feature: @dashboards
      )
      @source_price = create_mapped_price(
        plan: @source_plan,
        product_id: SOURCE_PRODUCT_ID,
        variant_id: SOURCE_VARIANT_ID,
        amount_cents: 4_900
      )

      @upgrade_plan = create_test_plan(name: "Capability Upgrade", position: 1)
      upgrade_plan_product = create_test_plan_product(plan: @upgrade_plan, product: @analytics)
      create_test_entitlement(
        plan_product: upgrade_plan_product,
        product_feature: @report_limit,
        limit_value: 10
      )
      create_test_entitlement(plan_product: upgrade_plan_product, product_feature: @dashboards)
      create_test_entitlement(plan_product: upgrade_plan_product, product_feature: @csv_export)
      @upgrade_price = create_mapped_price(
        plan: @upgrade_plan,
        product_id: UPGRADE_PRODUCT_ID,
        variant_id: UPGRADE_VARIANT_ID,
        amount_cents: 7_900
      )

      @downgrade_plan = create_test_plan(name: "Capability Downgrade", position: 200)
      downgrade_plan_product = create_test_plan_product(plan: @downgrade_plan, product: @analytics)
      create_test_entitlement(
        plan_product: downgrade_plan_product,
        product_feature: @report_limit,
        limit_value: 2
      )
      create_test_entitlement(plan_product: downgrade_plan_product, product_feature: @dashboards)
      @downgrade_price = create_mapped_price(
        plan: @downgrade_plan,
        product_id: DOWNGRADE_PRODUCT_ID,
        variant_id: DOWNGRADE_VARIANT_ID,
        amount_cents: 2_900
      )

      @yearly_price = create_mapped_price(
        plan: @source_plan,
        product_id: YEARLY_PRODUCT_ID,
        variant_id: YEARLY_VARIANT_ID,
        amount_cents: 49_000,
        billing_interval: :yearly
      )
    end

    def create_subscription
      customer = create_billing_customer(
        organization: @organization,
        provider_customer_id: CUSTOMER_ID
      )
      @subscription = create_billing_subscription(
        organization: @organization,
        billing_customer: customer,
        plan_price: @source_price,
        provider_subscription_id: SUBSCRIPTION_ID,
        provider_customer_id: CUSTOMER_ID,
        provider_updated_at: 1.hour.ago.change(usec: 0),
        renews_at: 30.days.from_now.change(usec: 0),
        card_brand: "visa",
        card_last_four: "4242"
      )
    end

    def create_mapped_price(plan:, product_id:, variant_id:, amount_cents:, billing_interval: :monthly)
      price = create_test_plan_price(
        plan: plan,
        billing_interval: billing_interval,
        currency: "EUR",
        amount_cents: amount_cents,
        lemon_store_id: STORE_ID,
        lemon_product_id: product_id,
        lemon_variant_id: variant_id
      )
      create_billing_provider_price_mapping(plan_price: price)
      price
    end

    def create_reports(count)
      count.times do |index|
        @organization.analytics_reports.create!(
          name: "Billing usage report #{index}",
          description: "Synthetic billing compatibility usage."
        )
      end
    end

    def effective_plan
      Current.set(organization: @organization) { @organization.effective_plan }
    end

    def sign_in_role(role)
      user = create_test_user(
        name: "Billing #{role}",
        email_address: "billing-management-#{role}-#{SecureRandom.hex(5)}@example.test"
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
      OrganizationAccessLocator.create!(
        organization: membership.organization,
        organization_membership: membership,
        user: membership.user
      )
    end

    def stub_variant_update(
      price,
      product_id: price.lemon_product_id,
      variant_id: price.lemon_variant_id
    )
      stub_request(:patch, subscription_url).to_return(
        status: 200,
        body: subscription_payload(
          product_id: product_id,
          variant_id: variant_id
        ).to_json
      )
    end

    def subscription_payload(product_id:, variant_id:)
      provider_updated_at = @subscription.provider_updated_at + 1.minute
      {
        data: {
          type: "subscriptions",
          id: SUBSCRIPTION_ID,
          attributes: {
            store_id: STORE_ID.to_i,
            customer_id: CUSTOMER_ID.to_i,
            product_id: product_id.to_i,
            variant_id: variant_id.to_i,
            status: "active",
            card_brand: "visa",
            card_last_four: "4242",
            pause: nil,
            trial_ends_at: nil,
            renews_at: 30.days.from_now.iso8601(6),
            ends_at: nil,
            created_at: (@subscription.provider_updated_at - 1.day).iso8601(6),
            updated_at: provider_updated_at.iso8601(6),
            test_mode: true
          }
        }
      }
    end

    def configure_lemon_environment
      values = {
        "LEMON_SQUEEZY_API_KEY" => "synthetic-billing-management-key",
        "LEMON_SQUEEZY_STORE_ID" => STORE_ID,
        "LEMON_SQUEEZY_ENVIRONMENT" => "test",
        "LEMON_SQUEEZY_CHECKOUT_HOST" => "billing-management.lemonsqueezy.test"
      }
      @previous_environment = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
    end

    def restore_lemon_environment
      @previous_environment&.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
end
