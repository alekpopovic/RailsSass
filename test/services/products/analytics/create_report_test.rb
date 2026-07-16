require "test_helper"
require_relative "../../../support/analytics_test_helper"

class Products::Analytics::CreateReportTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  teardown { Current.reset }

  test "creates through Current organization at the exact finite boundary and ignores untrusted semantics" do
    analytics = create_analytics_context(limit_value: 1)
    foreign_owner = create_test_user(email_address: "analytics-foreign-owner@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Analytics",
      slug: "foreign-analytics"
    )

    report = assert_difference("analytics.organization.analytics_reports.count", 1) do
      Products::Analytics::CreateReport.new(
        context: AuthorizationContext.current,
        attributes: {
          name: "  First report  ",
          description: "  Synthetic report.  ",
          organization_id: foreign_organization.id,
          permission_key: "client.permission",
          feature_key: "client_feature",
          capacity_delta: 0
        }
      ).call
    end

    assert_equal analytics.organization.id, report.organization_id
    assert_equal "First report", report.name
    assert_equal "Synthetic report.", report.description
    assert_empty foreign_organization.analytics_reports
  end

  test "rejects zero and exhausted finite capacity without persisting a report" do
    analytics = create_analytics_context(limit_value: 0)

    error = assert_no_difference("AnalyticsReport.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_report(name: "Blocked report")
      end
    end

    assert_equal [ Products::Analytics::CreateReport::LIMIT_REACHED_MESSAGE ],
      error.record.errors[:base]

    analytics.report_limit_entitlement.update!(limit_value: 1)
    create_report(name: "Allowed report")

    assert_no_difference("AnalyticsReport.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_report(name: "Over the boundary")
      end
    end
  end

  test "supports explicit unlimited capacity" do
    analytics = create_analytics_context(limit_value: nil, unlimited: true)

    assert_difference("analytics.organization.analytics_reports.count", 3) do
      3.times { |index| create_report(name: "Unlimited report #{index}") }
    end
  end

  test "a downgrade below current usage preserves existing reports and blocks new consumption" do
    analytics = create_analytics_context(limit_value: 2)
    2.times { |index| create_report(name: "Existing report #{index}") }

    analytics.report_limit_entitlement.update!(limit_value: 1)

    assert_equal 2, analytics.organization.analytics_reports.count
    assert_no_difference("AnalyticsReport.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_report(name: "Blocked after downgrade")
      end
    end
    assert_equal [ "Existing report 0", "Existing report 1" ],
      analytics.organization.analytics_reports.order(:id).pluck(:name)
  end

  test "revalidates both feature entitlement and permission inside the locked command" do
    analytics = create_analytics_context(limit_value: 1)
    analytics.custom_reports_entitlement.update!(enabled: false)

    assert_no_difference("AnalyticsReport.count") do
      assert_raises(Pundit::NotAuthorizedError) do
        create_report(name: "Missing feature")
      end
    end

    analytics.custom_reports_entitlement.update!(enabled: true)
    ProductRolePermission.where(product_role: analytics.role).delete_all

    assert_no_difference("AnalyticsReport.count") do
      assert_raises(Pundit::NotAuthorizedError) do
        create_report(name: "Missing permission")
      end
    end
  end

  test "returns model validation errors without consuming capacity" do
    analytics = create_analytics_context(limit_value: 1)

    error = assert_no_difference("analytics.organization.analytics_reports.count") do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_report(name: " ")
      end
    end

    assert_includes error.record.errors[:name], "can't be blank"
    assert_equal 1, Products::Analytics::ActionRegistry.decision(
      :report_create,
      context: AuthorizationContext.current
    ).capacity
  end

  private
    def create_report(name:)
      Products::Analytics::CreateReport.new(
        context: AuthorizationContext.current,
        attributes: { name: name, description: "Synthetic description." }
      ).call
    end
end
