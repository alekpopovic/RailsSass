require "test_helper"
require_relative "../support/analytics_customer_test_helper"

class AnalyticsCustomerProductRequestTest < ActionDispatch::IntegrationTest
  include AnalyticsCustomerTestHelper

  test "authorized customer creates reads and exports only tenant-owned reports" do
    catalog = create_analytics_catalog(report_limit: 3)
    tenant = create_analytics_tenant(catalog: catalog, prefix: "analytics-full")
    other_tenant = create_analytics_tenant(catalog: catalog, prefix: "analytics-other")
    foreign_report = other_tenant.organization.analytics_reports.create!(
      name: "Foreign private report",
      description: "Must not cross the tenant boundary."
    )
    sign_in_as(tenant.user)

    get organization_analytics_dashboard_path(
      organization_slug: tenant.organization.slug
    )
    assert_response :success
    assert_select "h1", "Analytics dashboard"

    get organization_analytics_reports_path(
      organization_slug: tenant.organization.slug
    )
    assert_response :success
    assert_select "h2", "No reports yet"
    assert_no_match foreign_report.name, response.body

    assert_difference -> { tenant.organization.analytics_reports.count }, 1 do
      assert_no_difference -> { other_tenant.organization.analytics_reports.count } do
        post organization_analytics_reports_path(
          organization_slug: tenant.organization.slug
        ), params: {
          analytics_report: {
            name: "Quarterly metrics",
            description: "Synthetic customer report.",
            organization_id: other_tenant.organization.id
          }
        }
      end
    end

    report = tenant.organization.analytics_reports.order(:id).last!
    assert_response :see_other
    assert_redirected_to organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: report.public_id
    )
    assert_equal "Quarterly metrics", report.name

    get organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: report.public_id
    )
    assert_response :success
    assert_select "h1", report.name
    assert_select "a", "Export CSV"

    get export_organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: report.public_id,
      format: :csv
    )
    assert_response :success
    assert_includes response.media_type, "text/csv"
    assert_match(/attachment/, response.headers.fetch("Content-Disposition"))
    assert_match report.public_id, response.body
    assert_match "Quarterly metrics", response.body

    get organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: foreign_report.public_id
    )
    assert_response :not_found

    get export_organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: foreign_report.public_id,
      format: :csv
    )
    assert_response :not_found
  end

  test "direct requests fail closed for missing entitlement and missing permission" do
    catalog = create_analytics_catalog(custom_reports_enabled: false)
    entitlement_denied = create_analytics_tenant(
      catalog: catalog,
      prefix: "analytics-entitlement-denied"
    )
    sign_in_as(entitlement_denied.user)

    assert_no_difference -> { entitlement_denied.organization.analytics_reports.count } do
      post organization_analytics_reports_path(
        organization_slug: entitlement_denied.organization.slug
      ), params: {
        analytics_report: { name: "Bypass entitlement", description: "Denied." }
      }
      assert_response :forbidden
    end

    delete session_path
    catalog.entitlements.fetch(:custom_reports).update!(enabled: true)
    permission_denied = create_analytics_tenant(
      catalog: catalog,
      prefix: "analytics-permission-denied",
      permissions: ANALYTICS_PERMISSIONS - [ "analytics.report.create" ]
    )
    sign_in_as(permission_denied.user)

    get organization_analytics_reports_path(
      organization_slug: permission_denied.organization.slug
    )
    assert_response :success
    assert_match "role allows report reading but not report creation", response.body

    assert_no_difference -> { permission_denied.organization.analytics_reports.count } do
      post organization_analytics_reports_path(
        organization_slug: permission_denied.organization.slug
      ), params: {
        analytics_report: { name: "Bypass permission", description: "Denied." }
      }
      assert_response :forbidden
    end
  end

  test "report creation enforces the organization-wide finite limit in the command" do
    catalog = create_analytics_catalog(report_limit: 1)
    tenant = create_analytics_tenant(catalog: catalog, prefix: "analytics-limit")
    tenant.organization.analytics_reports.create!(
      name: "Existing report",
      description: "Consumes the only report unit."
    )
    sign_in_as(tenant.user)

    assert_no_difference -> { tenant.organization.analytics_reports.count } do
      post organization_analytics_reports_path(
        organization_slug: tenant.organization.slug
      ), params: {
        analytics_report: { name: "Over the limit", description: "Denied." }
      }
      assert_response :unprocessable_entity
    end
    assert_select "[role='alert']", text: /report limit has been reached/
  end

  test "dashboard and export permissions are independently enforced by direct requests" do
    catalog = create_analytics_catalog
    tenant = create_analytics_tenant(
      catalog: catalog,
      prefix: "analytics-read-only",
      permissions: [ "analytics.report.read" ]
    )
    report = tenant.organization.analytics_reports.create!(
      name: "Readable report",
      description: "Not exportable."
    )
    sign_in_as(tenant.user)

    get organization_analytics_dashboard_path(
      organization_slug: tenant.organization.slug
    )
    assert_response :forbidden

    get organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: report.public_id
    )
    assert_response :success
    assert_select "a", text: "Export CSV", count: 0

    get export_organization_analytics_report_path(
      organization_slug: tenant.organization.slug,
      public_id: report.public_id,
      format: :csv
    )
    assert_response :forbidden
  end
end
