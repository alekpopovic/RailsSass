require_relative "billing_test_helper"
require_relative "product_rbac_test_helper"

module AnalyticsCustomerTestHelper
  include BillingTestHelper
  include ProductRbacTestHelper

  ANALYTICS_PERMISSIONS = Products::Analytics::ActionRegistry::ACTIONS
    .values
    .map(&:permission_key)
    .uniq
    .freeze

  AnalyticsCatalog = Data.define(
    :product,
    :features,
    :plan,
    :plan_product,
    :entitlements,
    :price
  )

  AnalyticsTenant = Data.define(
    :user,
    :organization,
    :membership,
    :product_membership,
    :product_role,
    :subscription
  )

  def create_analytics_catalog(
    plan_name: "Professional",
    report_limit: 5,
    dashboards_enabled: true,
    custom_reports_enabled: true,
    csv_export_enabled: true
  )
    suffix = SecureRandom.hex(5)
    product = Product.create!(
      key: "analytics",
      name: "Analytics",
      description: "Synthetic Analytics catalog for customer access tests.",
      active: true
    )
    features = {
      dashboards: create_test_product_feature(
        product: product,
        key: "dashboards",
        name: "Dashboards"
      ),
      custom_reports: create_test_product_feature(
        product: product,
        key: "custom_reports",
        name: "Custom reports"
      ),
      csv_export: create_test_product_feature(
        product: product,
        key: "csv_export",
        name: "CSV export"
      ),
      report_limit: create_test_product_feature(
        product: product,
        key: "report_limit",
        name: "Report limit",
        kind: :limit
      )
    }
    plan = create_test_plan(
      key: "analytics_professional_#{suffix}",
      name: plan_name,
      description: "Synthetic Analytics plan.",
      position: 20
    )
    plan_product = create_test_plan_product(plan: plan, product: product)
    entitlements = {
      dashboards: create_test_entitlement(
        plan_product: plan_product,
        product_feature: features.fetch(:dashboards),
        enabled: dashboards_enabled
      ),
      custom_reports: create_test_entitlement(
        plan_product: plan_product,
        product_feature: features.fetch(:custom_reports),
        enabled: custom_reports_enabled
      ),
      csv_export: create_test_entitlement(
        plan_product: plan_product,
        product_feature: features.fetch(:csv_export),
        enabled: csv_export_enabled
      ),
      report_limit: create_test_entitlement(
        plan_product: plan_product,
        product_feature: features.fetch(:report_limit),
        limit_value: report_limit == :unlimited ? nil : report_limit,
        unlimited: report_limit == :unlimited
      )
    }
    price = create_test_plan_price(plan: plan)

    AnalyticsCatalog.new(
      product: product,
      features: features.freeze,
      plan: plan,
      plan_product: plan_product,
      entitlements: entitlements.freeze,
      price: price
    )
  end

  def create_analytics_tenant(
    catalog:,
    prefix: "analytics-customer",
    permissions: ANALYTICS_PERMISSIONS,
    subscription_plan: catalog.plan,
    product_membership: true,
    organization_role: :owner
  )
    suffix = SecureRandom.hex(5)
    user = create_test_user(
      name: "Analytics Customer",
      email_address: "#{prefix}-#{suffix}@example.test"
    )
    organization = create_test_organization(
      name: "#{prefix.titleize} #{suffix}",
      slug: "#{prefix.parameterize}-#{suffix}"
    )
    membership = create_test_membership(
      organization: organization,
      user: user,
      role: organization_role
    )
    OrganizationAccessLocator.create!(
      organization: organization,
      organization_membership: membership,
      user: user
    )

    price = if subscription_plan.id == catalog.plan.id
      catalog.price
    else
      subscription_plan.plan_prices.where(active: true).first || create_test_plan_price(plan: subscription_plan)
    end
    subscription = create_billing_subscription(
      organization: organization,
      plan_price: price
    )

    assigned_membership = nil
    role = nil
    if product_membership
      assigned_membership = create_test_product_membership(
        organization_membership: membership,
        product: catalog.product
      )
      role = create_test_product_role(
        product: catalog.product,
        key: "customer_role_#{suffix}",
        name: "Customer role"
      )
      Array(permissions).each do |permission_key|
        permission = catalog.product.product_permissions.find_or_create_by!(key: permission_key) do |record|
          record.name = permission_key.titleize
          record.description = "Synthetic permission for customer access tests."
        end
        create_test_product_role_permission(
          product_role: role,
          product_permission: permission
        )
      end
      create_test_product_membership_role(
        product_membership: assigned_membership,
        product_role: role
      )
    end

    AnalyticsTenant.new(
      user: user,
      organization: organization,
      membership: membership,
      product_membership: assigned_membership,
      product_role: role,
      subscription: subscription
    )
  end
end
