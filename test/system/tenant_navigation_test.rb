require "application_system_test_case"
require_relative "../support/organization_test_helper"

class TenantNavigationTest < ApplicationSystemTestCase
  include OrganizationTestHelper

  test "a user switches between organizations through revalidated tenant paths" do
    user = create_test_user(email_address: "system-switcher@example.test")
    first = create_tenant_for(user, name: "System First", slug: "system-first")
    second = create_tenant_for(user, name: "System Second", slug: "system-second")

    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path

    visit organization_dashboard_path(organization_slug: first.slug)
    page.current_window.resize_to(390, 844)
    assert_selector "nav[aria-label='Organization navigation']"
    find("summary", text: "System First").send_keys(:enter)
    find_link("System Second").send_keys(:enter)

    assert_current_path organization_dashboard_path(organization_slug: second.slug)
    assert_selector "h1", text: "System Second"
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private
    def create_tenant_for(user, name:, slug:)
      organization, membership = create_test_organization_with_owner(
        owner: user,
        name: name,
        slug: slug
      )
      OrganizationAccessLocator.create!(
        organization_membership: membership,
        organization: organization,
        user: user
      )
      organization
    end
end
