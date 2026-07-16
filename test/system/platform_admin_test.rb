require "application_system_test_case"
require_relative "../support/organization_test_helper"

class PlatformAdminTest < ApplicationSystemTestCase
  include OrganizationTestHelper

  test "platform administrator navigates the console and manages a product lifecycle" do
    administrator = create_test_user(
      name: "System Platform Administrator",
      email_address: "system-platform-admin@example.test"
    )
    administrator.update!(system_role: :platform_admin)
    sign_in(administrator)

    assert_link "Admin", href: admin_root_path
    click_link "Admin"

    assert_current_path admin_root_path
    assert_selector "nav[aria-label='Platform administration']"
    assert_selector "h1", text: "Products"

    click_link "Plans"
    assert_current_path admin_plans_path
    assert_selector "h1", text: "Plans"

    click_link "Subscriptions"
    assert_current_path admin_billing_subscriptions_path
    assert_selector "h1", text: "Subscriptions"

    click_link "Failed webhooks"
    assert_current_path admin_billing_webhook_events_path
    assert_selector "h1", text: "Failed webhook events"

    click_link "Products"
    click_link "New product"
    fill_in "Stable key", with: "system_workspace"
    fill_in "Name", with: "System Workspace"
    fill_in "Description", with: "Synthetic product created by the platform admin system test."
    click_button "Create product"

    assert_current_path admin_product_path("system_workspace")
    assert_selector "[role='status']", text: "Product created."
    assert_selector "h1", text: "System Workspace"
    assert_text "Active"

    click_link "Edit product"
    assert_no_field "Stable key"
    assert_text "system_workspace"
    fill_in "Name", with: "System Workspace Updated"
    fill_in "Description", with: "Updated synthetic catalog presentation."
    uncheck "Active for new catalog selections"
    click_button "Save product"

    assert_current_path admin_product_path("system_workspace")
    assert_selector "[role='status']", text: "Product updated."
    assert_selector "h1", text: "System Workspace Updated"
    assert_text "Inactive"

    product = Product.find_by!(key: "system_workspace")
    assert_not_predicate product, :active?
    assert_equal %w[catalog.created catalog.deactivated],
      administrator.platform_audit_events_as_actor.order(:id).pluck(:action)
  end

  test "organization owner without platform role cannot access the console" do
    owner = create_test_user(
      name: "System Organization Owner",
      email_address: "system-organization-owner@example.test"
    )
    organization, membership = create_test_organization_with_owner(
      owner: owner,
      name: "System Owner Organization",
      slug: "system-owner-organization"
    )
    OrganizationAccessLocator.create!(
      organization: organization,
      organization_membership: membership,
      user: owner
    )
    sign_in(owner)

    assert_no_link "Admin"
    visit admin_root_path

    assert_current_path admin_root_path
    assert_title "Forbidden (403)"
    assert_text "You are not allowed to access this page."
    assert_no_selector "nav[aria-label='Platform administration']"
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
