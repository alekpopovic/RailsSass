require "test_helper"
require_relative "../support/billing_test_helper"
require_relative "../support/product_rbac_test_helper"

class CustomerShellRequestTest < ActionDispatch::IntegrationTest
  include BillingTestHelper
  include ProductRbacTestHelper

  setup do
    suffix = SecureRandom.hex(5)
    @owner = create_test_user(
      name: "Shell Owner",
      email_address: "shell-owner-#{suffix}@example.test"
    )
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Shell Organization #{suffix}",
      slug: "shell-organization-#{suffix}"
    )
    create_locator_for(@owner_membership)
    sign_in_as(@owner)
  end

  test "profile is self-only and public parameters cannot change identity or system role" do
    get profile_path

    assert_response :success
    assert_select "h1", "Profile settings"
    assert_select "form[action=?]", profile_path
    assert_select "input[name='user[name]']"
    assert_select "input[name='user[email_address]']", count: 0
    assert_select "input[name='user[system_role]']", count: 0
    assert_match @owner.email_address, response.body

    patch profile_path, params: {
      user: {
        name: "Updated Shell Owner",
        email_address: "attacker@example.test",
        system_role: "platform_admin"
      }
    }

    assert_response :see_other
    assert_redirected_to profile_path
    @owner.reload
    assert_equal "Updated Shell Owner", @owner.name
    assert_not_equal "attacker@example.test", @owner.email_address
    assert_predicate @owner, :user?
  end

  test "owner updates organization display name through an audited tenant request" do
    get organization_settings_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "input[name='organization[name]']"
    assert_select "input[name='organization[slug]']", count: 0

    assert_difference -> { @organization.audit_events.count }, 1 do
      patch organization_settings_path(organization_slug: @organization.slug), params: {
        organization: { name: "Customer Shell Renamed", slug: "changed-slug" }
      }
    end

    assert_response :see_other
    @organization.reload
    assert_equal "Customer Shell Renamed", @organization.name
    assert_match(/shell-organization-/, @organization.slug)
  end

  test "a direct settings update by an ordinary member is forbidden" do
    delete session_path
    member = create_test_user(email_address: "shell-settings-member-#{SecureRandom.hex(5)}@example.test")
    membership = create_test_membership(
      organization: @organization,
      user: member,
      role: :member
    )
    create_locator_for(membership)
    sign_in_as(member)

    assert_no_changes -> { @organization.reload.name } do
      patch organization_settings_path(organization_slug: @organization.slug), params: {
        organization: { name: "Unauthorized Rename" }
      }
      assert_response :forbidden
    end
  end

  test "dashboard and pricing render local plan state with responsive shell navigation" do
    suffix = SecureRandom.hex(4)
    plan = create_test_plan(
      key: "shell_starter_#{suffix}",
      name: "Shell Starter",
      description: "A synthetic shell plan.",
      free: true
    )
    paid_plan = create_test_plan(
      key: "shell_professional_#{SecureRandom.hex(4)}",
      name: "Shell Professional",
      description: "A synthetic paid shell plan.",
      position: 20
    )
    create_test_plan_price(
      plan: paid_plan,
      billing_interval: :monthly,
      currency: "EUR",
      amount_cents: 1_500
    )
    enabled_product = create_test_product(
      key: "shell_enabled_#{suffix}",
      name: "Enabled Shell Product"
    )
    unentitled_product = create_test_product(
      key: "shell_unentitled_#{suffix}",
      name: "Unentitled Shell Product"
    )
    listed_product = create_test_product(
      key: "shell_listed_#{suffix}",
      name: "Listed Paid Product"
    )
    archived_product = create_test_product(
      key: "shell_archived_#{suffix}",
      name: "Archived Paid Product",
      active: false
    )
    create_test_plan_product(plan: plan, product: enabled_product)
    create_test_plan_product(plan: paid_plan, product: listed_product)
    create_test_plan_product(plan: paid_plan, product: archived_product)
    create_test_product_membership(
      organization_membership: @owner_membership,
      product: enabled_product
    )
    create_test_product_membership(
      organization_membership: @owner_membership,
      product: unentitled_product
    )

    get organization_dashboard_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "h1", @organization.name
    assert_select "a[href=?]", organization_products_path(organization_slug: @organization.slug)
    assert_select "a[href=?]", organization_pricing_path(organization_slug: @organization.slug)
    assert_match "Shell Starter", response.body
    assert_select "div", text: /Product assignments\s*1\s*Active seats across enabled products/

    get organization_pricing_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "h1", /plan comparison/i
    assert_match "EUR", response.body
    assert_match "Current plan", response.body
    assert_match listed_product.name, response.body
    assert_no_match archived_product.name, response.body
    assert_not_requested :any, %r{\Ahttps://api\.lemonsqueezy\.com/}
  end

  test "billing overview reads only the current local subscription projection" do
    paid_plan = create_test_plan(
      key: "shell_paid_#{SecureRandom.hex(4)}",
      name: "Local Professional"
    )
    price = create_test_plan_price(
      plan: paid_plan,
      billing_interval: :yearly,
      currency: "EUR",
      amount_cents: 24_000
    )
    customer = create_billing_customer(organization: @organization)
    subscription = create_billing_subscription(
      organization: @organization,
      billing_customer: customer,
      plan_price: price,
      provider_subscription_id: "provider-secret-identity",
      renews_at: 1.year.from_now
    )

    get organization_billing_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "h1", "Billing overview"
    assert_match paid_plan.name, response.body
    assert_match subscription.status.humanize, response.body
    assert_no_match subscription.provider_subscription_id, response.body
    assert_no_match(/raw_payload|lemon_variant_id|API key/i, response.body)
    assert_not_requested :any, %r{\Ahttps://api\.lemonsqueezy\.com/}
  end

  test "product catalog distinguishes required plan from missing dashboard permission" do
    suffix = SecureRandom.hex(4)
    analytics = create_test_product(key: "analytics", name: "Analytics")
    dashboards = create_test_product_feature(
      product: analytics,
      key: "dashboards",
      name: "Dashboards"
    )
    starter = create_test_plan(key: "shell_free_#{suffix}", name: "Starter", free: true)
    professional = create_test_plan(
      key: "shell_professional_#{suffix}",
      name: "Professional",
      position: 20
    )
    professional_product = create_test_plan_product(plan: professional, product: analytics)
    create_test_entitlement(
      plan_product: professional_product,
      product_feature: dashboards
    )
    basic = create_test_plan(
      key: "shell_basic_#{suffix}",
      name: "Basic without dashboards",
      position: 15
    )
    create_test_plan_product(plan: basic, product: analytics)

    get organization_products_path(organization_slug: @organization.slug)

    assert_response :success
    assert_select "article", text: /Analytics.*Locked.*Professional/m
    assert_match "Professional plan is required", response.body
    assert_select "a[href=?]",
      organization_product_members_path(
        organization_slug: @organization.slug,
        product_key: analytics.key
      ), count: 0

    starter_product = create_test_plan_product(plan: starter, product: analytics)
    create_test_entitlement(plan_product: starter_product, product_feature: dashboards)
    product_membership = create_test_product_membership(
      organization_membership: @owner_membership,
      product: analytics
    )
    role = create_test_product_role(product: analytics, key: "shell_no_dashboard")
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: role
    )
    Rails.cache.clear

    get organization_products_path(organization_slug: @organization.slug)

    assert_response :success
    assert_match "missing Analytics dashboard permission", response.body
    assert_no_match "Professional plan is required", response.body
    assert_select "a[href=?]",
      organization_product_members_path(
        organization_slug: @organization.slug,
        product_key: analytics.key
      ), text: "Manage product members"
  end

  private
    def create_locator_for(membership)
      OrganizationAccessLocator.find_or_create_by!(
        organization_membership: membership,
        organization: membership.organization,
        user: membership.user
      )
    end
end
