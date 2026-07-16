require_relative "billing_test_helper"
require_relative "product_rbac_test_helper"

module AnalyticsTestHelper
  include BillingTestHelper
  include ProductRbacTestHelper

  AnalyticsContext = Data.define(
    :user,
    :organization,
    :organization_membership,
    :session,
    :product,
    :custom_reports_feature,
    :report_limit_feature,
    :plan,
    :plan_product,
    :custom_reports_entitlement,
    :report_limit_entitlement,
    :plan_price,
    :subscription,
    :permission,
    :role,
    :product_membership
  )

  def create_analytics_context(
    limit_value: 1,
    unlimited: false,
    custom_reports_enabled: true,
    permission_key: "analytics.report.create",
    use_paid_plan: true
  )
    suffix = SecureRandom.hex(6)
    product = analytics_product
    custom_reports_feature = analytics_feature(
      product: product,
      key: "custom_reports",
      kind: "flag"
    )
    report_limit_feature = analytics_feature(
      product: product,
      key: "report_limit",
      kind: "limit"
    )
    plan = analytics_plan(suffix: suffix, use_paid_plan: use_paid_plan)
    plan_product = PlanProduct.find_or_create_by!(plan: plan, product: product)
    custom_reports_entitlement = ensure_analytics_entitlement(
      plan_product: plan_product,
      product_feature: custom_reports_feature,
      enabled: custom_reports_enabled,
      limit_value: nil,
      unlimited: false
    )
    report_limit_entitlement = ensure_analytics_entitlement(
      plan_product: plan_product,
      product_feature: report_limit_feature,
      enabled: true,
      limit_value: unlimited ? nil : limit_value,
      unlimited: unlimited
    )
    plan_price = create_test_plan_price(plan: plan) if use_paid_plan

    user = create_test_user(email_address: "analytics-user-#{suffix}@example.test")
    organization, organization_membership = create_test_organization_with_owner(
      owner: user,
      name: "Analytics Tenant #{suffix}",
      slug: "analytics-tenant-#{suffix}"
    )
    subscription = if use_paid_plan
      create_billing_subscription(
        organization: organization,
        plan_price: plan_price
      )
    end
    permission = analytics_permission(product: product, key: permission_key)
    role = create_test_product_role(
      product: product,
      key: "analytics_role_#{suffix}",
      name: "Analytics test role"
    )
    create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )
    product_membership = create_test_product_membership(
      organization_membership: organization_membership,
      product: product
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: role
    )
    session = establish_tenant_context(
      user: user,
      organization: organization,
      membership: organization_membership
    )

    AnalyticsContext.new(
      user: user,
      organization: organization,
      organization_membership: organization_membership,
      session: session,
      product: product,
      custom_reports_feature: custom_reports_feature,
      report_limit_feature: report_limit_feature,
      plan: plan,
      plan_product: plan_product,
      custom_reports_entitlement: custom_reports_entitlement,
      report_limit_entitlement: report_limit_entitlement,
      plan_price: plan_price,
      subscription: subscription,
      permission: permission,
      role: role,
      product_membership: product_membership
    )
  end

  private
    def analytics_product
      Product.find_or_create_by!(key: Products::Analytics::ActionRegistry::PRODUCT_KEY) do |product|
        product.name = "Analytics"
        product.description = "Synthetic Analytics product for tests."
        product.active = true
      end
    end

    def analytics_feature(product:, key:, kind:)
      feature = product.product_features.find_or_initialize_by(key: key)
      if feature.persisted? && feature.kind != kind
        raise "Analytics feature #{key} has the wrong kind"
      end

      if feature.new_record?
        feature.assign_attributes(
          name: key.humanize,
          description: "Synthetic Analytics #{key.humanize.downcase} feature.",
          kind: kind,
          active: true
        )
        feature.save!
      end
      feature
    end

    def analytics_permission(product:, key:)
      product.product_permissions.find_or_create_by!(key: key) do |permission|
        permission.name = key.humanize
        permission.description = "Synthetic Analytics permission."
      end
    end

    def analytics_plan(suffix:, use_paid_plan:)
      if use_paid_plan
        create_test_plan(
          key: "analytics_plan_#{suffix}",
          name: "Analytics Plan #{suffix}",
          free: false
        )
      else
        Plan.find_by(active: true, free: true) || create_test_plan(
          key: "analytics_free_#{suffix}",
          name: "Analytics Free #{suffix}",
          free: true
        )
      end
    end

    def ensure_analytics_entitlement(plan_product:, product_feature:, **attributes)
      entitlement = PlanFeatureEntitlement.find_or_initialize_by(
        plan_product: plan_product,
        product_feature: product_feature
      )
      entitlement.assign_attributes(attributes)
      entitlement.settings = {}
      entitlement.save!
      entitlement
    end
end
