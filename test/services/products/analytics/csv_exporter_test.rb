require "test_helper"
require "csv"
require_relative "../../../support/organization_test_helper"

class Products::Analytics::CsvExporterTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  teardown { Current.reset }

  test "exports a tenant-owned report with fixed headers UTC time and formula-safe user cells" do
    owner = create_test_user(email_address: "analytics-csv-owner@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: owner,
      name: "Analytics CSV",
      slug: "analytics-csv"
    )
    establish_tenant_context(user: owner, organization: organization, membership: membership)
    report = organization.analytics_reports.create!(
      name: "=HYPERLINK(\"https://example.test\")",
      description: "  +SUM(1,1)"
    )

    rows = CSV.parse(Products::Analytics::CsvExporter.new(report).call)

    assert_equal Products::Analytics::CsvExporter::HEADERS, rows.first
    assert_equal report.public_id, rows.second.fetch(0)
    assert_equal "'=HYPERLINK(\"https://example.test\")", rows.second.fetch(1)
    assert_equal "'+SUM(1,1)", rows.second.fetch(2)
    assert_equal report.created_at.utc.iso8601(6), rows.second.fetch(3)
  end

  test "refuses a report from another organization or an unsaved report" do
    first_owner = create_test_user(email_address: "analytics-csv-first@example.test")
    first_organization, first_membership = create_test_organization_with_owner(
      owner: first_owner,
      name: "First CSV",
      slug: "first-csv"
    )
    second_owner = create_test_user(email_address: "analytics-csv-second@example.test")
    second_organization, = create_test_organization_with_owner(
      owner: second_owner,
      name: "Second CSV",
      slug: "second-csv"
    )
    establish_tenant_context(
      user: first_owner,
      organization: first_organization,
      membership: first_membership
    )
    foreign_report = second_organization.analytics_reports.create!(name: "Foreign")

    assert_raises(ActiveRecord::RecordNotFound) do
      Products::Analytics::CsvExporter.new(foreign_report).call
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Products::Analytics::CsvExporter.new(
        first_organization.analytics_reports.new(name: "Unsaved")
      ).call
    end
  end
end
