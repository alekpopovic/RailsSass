require "application_system_test_case"
require_relative "../support/analytics_customer_test_helper"

class ProductAccessTest < ApplicationSystemTestCase
  include AnalyticsCustomerTestHelper

  test "authorized customer uses the Analytics report vertical slice" do
    catalog = create_analytics_catalog(report_limit: 2)
    tenant = create_analytics_tenant(catalog: catalog, prefix: "system-analytics-full")
    sign_in_in_browser(tenant.user)

    visit organization_products_path(organization_slug: tenant.organization.slug)
    within("article", text: "Analytics") do
      assert_text "Available"
      click_link "Open Analytics"
    end

    assert_selector "h1", text: "Analytics dashboard"
    click_link "View reports"
    assert_text "No reports yet"
    click_link "New report"

    fill_in "Name", with: "System funnel report"
    fill_in "Description", with: "A synthetic end-to-end report."
    click_button "Create report"

    assert_selector "h1", text: "System funnel report"
    assert_text "A synthetic end-to-end report."
    assert_link "Export CSV"
    assert_equal tenant.organization, AnalyticsReport.order(:id).last!.organization
  end

  test "locked product names the required plan and direct navigation stays denied" do
    catalog = create_analytics_catalog(plan_name: "Professional")
    starter = create_test_plan(
      key: "system_starter_#{SecureRandom.hex(5)}",
      name: "Starter",
      description: "Synthetic plan without Analytics.",
      position: 0
    )
    tenant = create_analytics_tenant(
      catalog: catalog,
      prefix: "system-analytics-locked",
      subscription_plan: starter
    )
    sign_in_in_browser(tenant.user)

    visit organization_products_path(organization_slug: tenant.organization.slug)
    within("article", text: "Analytics") do
      assert_text "Locked"
      assert_text "Professional plan is required"
      assert_link "Compare plans"
      assert_no_link "Open Analytics"
    end

    visit organization_analytics_dashboard_path(
      organization_slug: tenant.organization.slug
    )
    assert_text "Access denied"
  end

  test "missing permission has a distinct message and direct navigation stays denied" do
    catalog = create_analytics_catalog
    tenant = create_analytics_tenant(
      catalog: catalog,
      prefix: "system-analytics-permission",
      permissions: ANALYTICS_PERMISSIONS - [ "analytics.dashboard.read" ]
    )
    sign_in_in_browser(tenant.user)

    visit organization_products_path(organization_slug: tenant.organization.slug)
    within("article", text: "Analytics") do
      assert_text "missing Analytics dashboard permission"
      assert_no_text "plan is required"
      assert_no_link "Open Analytics"
    end

    visit organization_analytics_dashboard_path(
      organization_slug: tenant.organization.slug
    )
    assert_text "Access denied"
  end

  test "guessed report ID from another organization is not found" do
    catalog = create_analytics_catalog
    tenant = create_analytics_tenant(catalog: catalog, prefix: "system-analytics-tenant")
    other_tenant = create_analytics_tenant(catalog: catalog, prefix: "system-analytics-foreign")
    foreign_report = other_tenant.organization.analytics_reports.create!(
      name: "Foreign system report",
      description: "Must never render in another tenant."
    )
    sign_in_in_browser(tenant.user)

    visit organization_analytics_reports_path(
      organization_slug: tenant.organization.slug
    )
    assert_no_text foreign_report.name

    visit organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: foreign_report.public_id
    )
    assert_text "Page not found"
    assert_no_text foreign_report.name
  end

  private
    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: AuthenticationTestHelper::TEST_PASSWORD
      click_button "Sign in"
      assert_current_path root_path
    end
end
