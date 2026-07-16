require "test_helper"
require_relative "../../support/catalog_test_helper"
require_relative "../../support/organization_test_helper"

class Products::PlanCompatibilityTest < ActiveSupport::TestCase
  include CatalogTestHelper
  include OrganizationTestHelper

  setup do
    suffix = SecureRandom.hex(5)
    @organization = create_test_organization(
      name: "Plan compatibility tenant #{suffix}",
      slug: "plan-compatibility-#{suffix}"
    )
    @analytics = create_test_product(key: "analytics", name: "Analytics")
    @report_limit = create_test_product_feature(
      product: @analytics,
      key: "report_limit",
      name: "Report limit",
      kind: :limit
    )
    Current.organization = @organization
  end

  teardown { Current.reset }

  test "accepts the exact finite boundary and explicit unlimited capacity" do
    plan = create_test_plan(name: "Boundary plan")
    entitlement = add_entitlement(
      plan: plan,
      product: @analytics,
      feature: @report_limit,
      limit_value: 2
    )
    create_reports(@organization, 2)

    exact = evaluate(to_plan: plan)

    assert_predicate exact, :compatible?
    assert_not_predicate exact, :over_limit?
    assert_equal :same_plan, exact.classification
    assert_empty exact.issues

    entitlement.update!(limit_value: nil, unlimited: true)
    unlimited = evaluate(to_plan: plan)

    assert_predicate unlimited, :compatible?
    key = capability_key("analytics", "report_limit")
    assert_equal Products::PlanCompatibility::UNLIMITED,
      unlimited.to_capabilities.limits.fetch(key)
  end

  test "treats a missing or disabled registered target limit as zero capacity" do
    create_reports(@organization, 1)
    missing_plan = create_test_plan(name: "Missing Analytics")

    missing = evaluate(to_plan: missing_plan)

    assert_predicate missing, :incompatible?
    assert_predicate missing, :over_limit?
    assert_limit_issue(missing.issues.sole, usage: 1, capacity: 0)

    disabled_plan = create_test_plan(name: "Disabled reports")
    add_entitlement(
      plan: disabled_plan,
      product: @analytics,
      feature: @report_limit,
      enabled: false,
      limit_value: 50
    )

    disabled = evaluate(to_plan: disabled_plan)

    assert_predicate disabled, :incompatible?
    assert_limit_issue(disabled.issues.sole, usage: 1, capacity: 0)
  end

  test "treats inactive catalog capabilities as unavailable runtime capacity" do
    plan = create_test_plan(name: "Inactive reports")
    add_entitlement(
      plan: plan,
      product: @analytics,
      feature: @report_limit,
      limit_value: 50
    )
    create_reports(@organization, 1)

    @report_limit.update!(active: false)
    inactive_feature = evaluate(to_plan: plan)
    assert_limit_issue(inactive_feature.issues.sole, usage: 1, capacity: 0)

    @report_limit.update!(active: true)
    @analytics.update!(active: false)
    inactive_product = evaluate(to_plan: plan)
    assert_limit_issue(inactive_product.issues.sole, usage: 1, capacity: 0)
  end

  test "fails closed for an enabled limit without a registered authoritative usage resolver" do
    crm = create_test_product(key: "crm", name: "CRM")
    contact_limit = create_test_product_feature(
      product: crm,
      key: "contact_limit",
      name: "Contact limit",
      kind: :limit
    )
    plan = create_test_plan(name: "Unregistered usage")
    add_entitlement(
      plan: plan,
      product: crm,
      feature: contact_limit,
      limit_value: 100
    )

    result = evaluate(to_plan: plan)
    issue = result.issues.sole

    assert_predicate result, :incompatible?
    assert_equal :usage_resolver_missing, issue.reason_code
    assert_equal "crm", issue.product_key
    assert_equal "contact_limit", issue.feature_key
    assert_equal 100, issue.capacity
    assert_nil issue.usage
    assert_nil issue.unit
    assert_equal "This plan limit cannot be verified safely.", issue.message
  end

  test "uses only Current organization authoritative usage and rejects another context" do
    foreign_organization = create_test_organization(
      name: "Foreign plan compatibility tenant",
      slug: "foreign-plan-compatibility-#{SecureRandom.hex(5)}"
    )
    create_reports(@organization, 1)
    create_reports(foreign_organization, 10)
    plan = create_test_plan(name: "Tenant-scoped limit")
    add_entitlement(
      plan: plan,
      product: @analytics,
      feature: @report_limit,
      limit_value: 1
    )

    result = evaluate(to_plan: plan)

    assert_predicate result, :compatible?

    Current.organization = foreign_organization
    assert_raises(ActiveRecord::RecordNotFound) do
      Products::PlanCompatibility.call(
        organization: @organization,
        to_plan: plan
      )
    end
  end

  test "classifies changes by stable capabilities instead of names or display position" do
    dashboards = create_test_product_feature(
      product: @analytics,
      key: "dashboards",
      name: "Dashboards",
      kind: :flag
    )
    csv_export = create_test_product_feature(
      product: @analytics,
      key: "csv_export",
      name: "CSV export",
      kind: :flag
    )
    source = plan_with_analytics(
      name: "Premium display name",
      position: 100,
      limit: 1,
      flags: [ dashboards ]
    )
    upgrade = plan_with_analytics(
      name: "Basic display name",
      position: 0,
      limit: 2,
      flags: [ dashboards, csv_export ]
    )
    downgrade = plan_with_analytics(
      name: "Ultimate display name",
      position: 200,
      limit: 0,
      flags: []
    )
    mixed = plan_with_analytics(
      name: "Mixed display name",
      position: 50,
      limit: 2,
      flags: []
    )
    equivalent = plan_with_analytics(
      name: "Different but equivalent plan",
      position: 999,
      limit: 1,
      flags: [ dashboards ]
    )

    assert_equal :upgrade, evaluate(from_plan: source, to_plan: upgrade).classification
    assert_equal :downgrade, evaluate(from_plan: source, to_plan: downgrade).classification
    assert_equal :change, evaluate(from_plan: source, to_plan: mixed).classification
    assert_equal :change, evaluate(from_plan: source, to_plan: equivalent).classification
    assert_equal :same_plan, evaluate(from_plan: source, to_plan: source).classification
  end

  test "returns deeply immutable UI-safe results and issues" do
    create_reports(@organization, 1)
    plan = create_test_plan(name: "Immutable result")

    result = evaluate(to_plan: plan)
    issue = result.issues.sole

    assert_predicate result, :frozen?
    assert_predicate result.issues, :frozen?
    assert_predicate issue, :frozen?
    assert_predicate issue.product_key, :frozen?
    assert_predicate issue.feature_key, :frozen?
    assert_predicate issue.unit, :frozen?
    assert_predicate result.from_capabilities, :frozen?
    assert_predicate result.to_capabilities, :frozen?
    assert_predicate result.to_capabilities.products, :frozen?
    assert_predicate result.to_capabilities.flags, :frozen?
    assert_predicate result.to_capabilities.enabled_limits, :frozen?
    assert_predicate result.to_capabilities.limits, :frozen?
    assert_equal "Current usage exceeds the selected plan limit.", issue.message
  end

  private
    def evaluate(to_plan:, from_plan: nil)
      Products::PlanCompatibility.call(
        organization: @organization,
        from_plan: from_plan,
        to_plan: to_plan
      )
    end

    def add_entitlement(plan:, product:, feature:, **attributes)
      plan_product = PlanProduct.find_or_create_by!(plan: plan, product: product)
      create_test_entitlement(
        plan_product: plan_product,
        product_feature: feature,
        **attributes
      )
    end

    def plan_with_analytics(name:, position:, limit:, flags:)
      plan = create_test_plan(name: name, position: position)
      add_entitlement(
        plan: plan,
        product: @analytics,
        feature: @report_limit,
        limit_value: limit
      )
      flags.each do |feature|
        add_entitlement(
          plan: plan,
          product: @analytics,
          feature: feature
        )
      end
      plan
    end

    def create_reports(organization, count)
      count.times do |index|
        organization.analytics_reports.create!(
          name: "Compatibility report #{index}",
          description: "Synthetic authoritative usage."
        )
      end
    end

    def capability_key(product_key, feature_key)
      Products::PlanCompatibility::CapabilityKey.new(
        product_key: product_key,
        feature_key: feature_key
      )
    end

    def assert_limit_issue(issue, usage:, capacity:)
      assert_equal :limit_exceeded, issue.reason_code
      assert_equal "analytics", issue.product_key
      assert_equal "report_limit", issue.feature_key
      assert_equal usage, issue.usage
      assert_equal capacity, issue.capacity
      assert_equal "reports", issue.unit
      assert_predicate issue, :over_limit?
    end
end
