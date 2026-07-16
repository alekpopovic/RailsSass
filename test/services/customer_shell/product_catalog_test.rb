require "test_helper"
require_relative "../../support/product_rbac_test_helper"

class CustomerShell::ProductCatalogTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  setup do
    suffix = SecureRandom.hex(5)
    @user = create_test_user(email_address: "shell-catalog-#{suffix}@example.test")
    @organization, @membership = create_test_organization_with_owner(
      owner: @user,
      name: "Shell Catalog #{suffix}",
      slug: "shell-catalog-#{suffix}"
    )
    establish_tenant_context(
      user: @user,
      organization: @organization,
      membership: @membership
    )
    @analytics = create_test_product(key: "analytics", name: "Analytics")
    @dashboards = create_test_product_feature(
      product: @analytics,
      key: "dashboards",
      name: "Dashboards"
    )
    @starter = create_test_plan(
      key: "starter_#{suffix}",
      name: "Starter",
      free: true,
      position: 10
    )
    @professional = create_test_plan(
      key: "professional_#{suffix}",
      name: "Professional",
      position: 20
    )
    professional_product = create_test_plan_product(
      plan: @professional,
      product: @analytics
    )
    create_test_entitlement(
      plan_product: professional_product,
      product_feature: @dashboards
    )
  end

  teardown do
    Current.reset
  end

  test "a product entitlement denial is locked and names the required active plan" do
    card = analytics_card

    assert_predicate card, :locked?
    assert_equal :product_not_in_plan, card.access_decision.reason_code
    assert_equal @professional, card.required_plan
    assert_equal "The Professional plan is required to unlock this product.", card.message
  end

  test "missing permission is distinct from missing entitlement" do
    enable_analytics_on_starter
    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: @analytics
    )
    role = create_test_product_role(product: @analytics, key: "shell_viewer")
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: role
    )

    card = analytics_card

    assert_equal :permission_missing, card.state
    assert_equal :permission_not_granted, card.access_decision.reason_code
    assert_nil card.required_plan
    assert_match(/missing Analytics dashboard permission/, card.message)
    assert_no_match(/plan is required/, card.message)
  end

  test "complete entitlement membership role and permission make Analytics available" do
    enable_analytics_on_starter
    permission = create_test_product_permission(
      product: @analytics,
      key: "analytics.dashboard.read"
    )
    role = create_test_product_role(product: @analytics, key: "shell_analyst")
    create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )
    product_membership = create_test_product_membership(
      organization_membership: @membership,
      product: @analytics
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: role
    )

    card = analytics_card

    assert_predicate card, :available?
    assert_equal :access_granted, card.access_decision.reason_code
    assert_nil card.required_plan
  end

  private
    def analytics_card
      CustomerShell::ProductCatalog.new(
        context: AuthorizationContext.current
      ).call.find { |card| card.product == @analytics }
    end

    def enable_analytics_on_starter
      plan_product = create_test_plan_product(plan: @starter, product: @analytics)
      create_test_entitlement(
        plan_product: plan_product,
        product_feature: @dashboards
      )
      Rails.cache.clear
    end
end
