require "test_helper"
require_relative "../support/organization_test_helper"

class AnalyticsReportTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    owner = create_test_user(email_address: "analytics-model-owner@example.test")
    @organization, = create_test_organization_with_owner(
      owner: owner,
      name: "Analytics Model",
      slug: "analytics-model"
    )
  end

  test "normalizes report content and assigns an immutable public UUID" do
    report = @organization.analytics_reports.create!(
      name: "  Weekly summary  ",
      description: "  Synthetic description.  "
    )

    assert_equal "Weekly summary", report.name
    assert_equal "Synthetic description.", report.description
    assert_match(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/, report.public_id)
    assert_includes @organization.analytics_reports, report
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      report.update!(organization: create_test_organization(name: "Other", slug: "analytics-model-other"))
    end
  end

  test "accepts an empty description but rejects missing or oversized names and descriptions" do
    report = @organization.analytics_reports.new(name: "Valid", description: nil)

    assert_predicate report, :valid?
    assert_equal "", report.description

    report.name = " "
    assert_not report.valid?
    assert_includes report.errors[:name], "can't be blank"

    report.name = "x" * 101
    report.description = "x" * 2_001
    assert_not report.valid?
    assert report.errors.added?(:name, :too_long, count: 100)
    assert report.errors.added?(:description, :too_long, count: 2_000)
  end

  test "organization deletion is restricted while reports exist" do
    @organization.analytics_reports.create!(name: "Retained report")

    assert_raises(ActiveRecord::DeleteRestrictionError) { @organization.destroy! }
  end
end
