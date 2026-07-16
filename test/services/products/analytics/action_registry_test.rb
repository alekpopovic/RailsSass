require "test_helper"
require_relative "../../../support/analytics_test_helper"

class Products::Analytics::ActionRegistryTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  teardown { Current.reset }

  test "registers exact server-owned permission feature and capacity contracts" do
    expected = {
      dashboard_read: [ "analytics.dashboard.read", [ [ "dashboards", :flag ] ], nil, 0 ],
      report_read: [ "analytics.report.read", [ [ "custom_reports", :flag ] ], nil, 0 ],
      report_create: [
        "analytics.report.create",
        [ [ "custom_reports", :flag ], [ "report_limit", :limit ] ],
        "report_limit",
        1
      ],
      report_manage: [ "analytics.report.manage", [ [ "custom_reports", :flag ] ], nil, 0 ],
      export_run: [ "analytics.export.run", [ [ "csv_export", :flag ] ], nil, 0 ]
    }

    actual = Products::Analytics::ActionRegistry::ACTIONS.transform_values do |action|
      [
        action.permission_key,
        action.feature_requirements.map { |requirement| [ requirement.key, requirement.kind ] },
        action.capacity_feature_key,
        action.capacity_delta
      ]
    end

    assert_equal expected, actual
    assert_predicate Products::Analytics::ActionRegistry::ACTIONS, :frozen?
  end

  test "report create evaluates both the flag and finite limit through the Access gate" do
    analytics = create_analytics_context(limit_value: 2)

    decision = Products::Analytics::ActionRegistry.decision(
      :report_create,
      context: AuthorizationContext.current
    )

    assert_predicate decision, :allowed?
    assert_equal :access_granted, decision.reason_code
    assert_equal 2, decision.capacity
    assert_equal 1, decision.capacity_delta
    assert_equal %w[custom_reports report_limit],
      decision.requirements_and_decisions.map { |requirement, _result| requirement.key }
    assert decision.requirements_and_decisions.all? { |_requirement, result|
      result.is_a?(Access::Decision) && result.allowed?
    }
    assert_equal analytics.plan.key, decision.access_decision.plan_key
  end

  test "returns the first safe entitlement denial and supports explicit unlimited capacity" do
    analytics = create_analytics_context(limit_value: 2, custom_reports_enabled: false)

    denied = Products::Analytics::ActionRegistry.decision(
      :report_create,
      context: AuthorizationContext.current
    )

    assert_predicate denied, :denied?
    assert_equal :feature_disabled, denied.reason_code
    assert_equal Access::Gate::FEATURE_PLAN_MESSAGE, denied.message

    analytics.custom_reports_entitlement.update!(enabled: true)
    analytics.report_limit_entitlement.update!(limit_value: nil, unlimited: true)
    allowed = Products::Analytics::ActionRegistry.decision(
      :report_create,
      context: AuthorizationContext.current
    )

    assert_predicate allowed, :allowed?
    assert_equal Access::Decision::UNLIMITED, allowed.capacity
  end

  test "fails closed without the registered permission and rejects unknown action names" do
    analytics = create_analytics_context(limit_value: 1)
    ProductRolePermission.where(product_role: analytics.role).delete_all

    decision = Products::Analytics::ActionRegistry.decision(
      :report_create,
      context: AuthorizationContext.current
    )

    assert_predicate decision, :denied?
    assert_equal :permission_not_granted, decision.reason_code
    assert_raises(KeyError) do
      Products::Analytics::ActionRegistry.decision(
        :client_supplied_action,
        context: AuthorizationContext.current
      )
    end
  end
end
