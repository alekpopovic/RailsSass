require "application_system_test_case"
require_relative "../support/billing_test_helper"

class BillingCheckoutTest < ApplicationSystemTestCase
  include BillingTestHelper

  test "owner sees an eligible pricing CTA and local-only pending status" do
    original_environment = Rails.configuration.x.billing.lemon_squeezy.environment
    original_store_id = Rails.configuration.x.billing.lemon_squeezy.store_id
    Rails.configuration.x.billing.lemon_squeezy.environment = "test"
    Rails.configuration.x.billing.lemon_squeezy.store_id = "810001"
    owner = create_test_user(email_address: "system-checkout-owner@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: owner,
      name: "System Checkout Organization",
      slug: "system-checkout-organization"
    )
    OrganizationAccessLocator.create!(
      organization: organization,
      organization_membership: membership,
      user: owner
    )
    plan = create_test_plan(name: "System Checkout Professional")
    plan_price = create_test_plan_price(
      plan: plan,
      lemon_store_id: "810001",
      lemon_product_id: "820002",
      lemon_variant_id: "830003"
    )
    create_billing_provider_price_mapping(plan_price: plan_price)
    sign_in(owner)

    visit organization_pricing_path(organization_slug: organization.slug)
    assert_button "Choose monthly"
    assert_text "Test mode — no real charge"

    attempt = create_billing_checkout_attempt(
      organization: organization,
      membership: membership,
      plan_price: plan_price,
      status: :ready,
      provider_checkout_id: SecureRandom.uuid
    )
    create_billing_provider_locator(
      organization: organization,
      checkout_attempt: attempt
    )
    visit organization_billing_checkout_pending_path(organization_slug: organization.slug)
    assert_selector "h1", text: "Payment confirmation pending"
    assert_selector "[role='status'][aria-live='polite']"
    assert_text "Waiting for verified payment confirmation"
    assert_text "Test mode"
    assert_link "Refresh status"
  ensure
    Rails.configuration.x.billing.lemon_squeezy.environment = original_environment
    Rails.configuration.x.billing.lemon_squeezy.store_id = original_store_id
  end

  private
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: TEST_PASSWORD
      click_button "Sign in"
      assert_current_path root_path
    end
end
