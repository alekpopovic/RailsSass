require "test_helper"
require_relative "../../support/product_rbac_test_helper"

class Access::GateTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(email_address: "gate-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Gate Organization #{suffix}",
      slug: "gate-organization-#{suffix}"
    )
    @user = create_test_user(email_address: "gate-member-#{suffix}@example.test")
    @membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :member
    )
    @session = establish_tenant_context(
      user: @user,
      organization: @organization,
      membership: @membership
    )

    @product = create_test_product(key: unique_catalog_key("analytics"))
    @feature = create_test_product_feature(
      product: @product,
      key: unique_catalog_key("exports")
    )
    @plan = create_test_plan(key: unique_catalog_key("starter"), free: true)
    @plan_product = create_test_plan_product(plan: @plan, product: @product)
    @entitlement = create_test_entitlement(
      plan_product: @plan_product,
      product_feature: @feature
    )
    @permission = create_test_product_permission(
      product: @product,
      key: "records.view"
    )
    @role = create_test_product_role(
      product: @product,
      key: unique_catalog_key("viewer")
    )
    @mapping = create_test_product_role_permission(
      product_role: @role,
      product_permission: @permission
    )
    @product_membership = add_product_membership(@membership)
    assign_role(@product_membership, @role)
  end

  teardown do
    Current.reset
  end

  test "returns a structured allowed decision for the complete product gate" do
    result = gate

    assert_instance_of Access::Decision, result
    assert_predicate result, :allowed?
    assert_equal true, result.allowed
    assert_equal :access_granted, result.reason_code
    assert_nil result.message
    assert_equal @plan.key, result.plan_key
    assert_equal :free, result.plan_source
    assert_equal @product.key, result.product_key
    assert_nil result.feature_key
    assert_equal :product_enabled, result.details.fetch(:entitlement_reason_code)
    assert_equal :no_current_subscription,
      result.details.fetch(:subscription_reason_code)
    assert_not_requested :any, %r{\Ahttps://api\.lemonsqueezy\.com/}
  end

  test "returns enabled flag and finite-limit metadata" do
    flag_result = gate(feature_key: @feature.key)

    assert_predicate flag_result, :allowed?
    assert_equal :flag, flag_result.feature_kind
    assert_nil flag_result.capacity
    assert_equal :feature_enabled,
      flag_result.details.fetch(:entitlement_reason_code)

    limit_feature = create_test_product_feature(
      product: @product,
      key: unique_catalog_key("seats"),
      kind: :limit
    )
    create_test_entitlement(
      plan_product: @plan_product,
      product_feature: limit_feature,
      limit_value: 0
    )
    limit_result = gate(feature_key: limit_feature.key)

    assert_predicate limit_result, :allowed?
    assert_equal :limit, limit_result.feature_kind
    assert_equal 0, limit_result.limit_value
    assert_equal 0, limit_result.capacity
  end

  test "preserves distinct product and feature entitlement denial reasons" do
    unknown_product = gate(product_key: "missing_product")
    ungranted_product = create_test_product(key: unique_catalog_key("crm"))
    not_in_plan = gate(product_key: ungranted_product.key)
    unknown_feature = gate(feature_key: "missing_feature")
    @entitlement.update!(enabled: false)
    disabled_feature = gate(feature_key: @feature.key)

    assert_denied unknown_product, :product_not_found, Access::Gate::PRODUCT_PLAN_MESSAGE
    assert_denied not_in_plan, :product_not_in_plan, Access::Gate::PRODUCT_PLAN_MESSAGE
    assert_denied unknown_feature, :feature_not_found, Access::Gate::FEATURE_PLAN_MESSAGE
    assert_denied disabled_feature, :feature_disabled, Access::Gate::FEATURE_PLAN_MESSAGE
    assert_equal @plan.key, disabled_feature.plan_key
    assert_equal @feature.key, disabled_feature.feature_key
  end

  test "requires an active product membership before checking permissions" do
    @product_membership.destroy!
    missing = gate

    @product_membership = add_product_membership(@membership)
    assign_role(@product_membership, @role)
    ProductMembership.where(id: @product_membership.id).update_all(
      status: "suspended",
      updated_at: Time.current
    )
    @mapping.destroy!
    suspended = gate

    assert_denied missing, :product_membership_missing, Access::Gate::PRODUCT_ACCESS_MESSAGE
    assert_denied suspended, :product_membership_suspended, Access::Gate::PRODUCT_ACCESS_MESSAGE
  end

  test "denies when no active role grants the exact permission" do
    @mapping.destroy!
    missing_permission = gate

    @mapping = create_test_product_role_permission(
      product_role: @role,
      product_permission: @permission
    )
    @role.update!(active: false)
    inactive_role = gate

    assert_denied missing_permission, :permission_not_granted, Access::Gate::PRODUCT_ACCESS_MESSAGE
    assert_denied inactive_role, :permission_not_granted, Access::Gate::PRODUCT_ACCESS_MESSAGE
  end

  test "checks authentication organization and membership before entitlements" do
    Current.session = nil
    authentication = gate
    Current.session = @session

    @user.update!(disabled_at: Time.current)
    disabled_user = gate
    @user.update!(disabled_at: nil)

    @organization.update!(status: :suspended)
    organization = gate
    @organization.update!(status: :active)

    suspend_current_organization_membership!
    organization_membership = gate(
      context: AuthorizationContext.new(
        user: @user,
        organization: @organization,
        membership: @membership.reload
      )
    )

    assert_denied authentication, :authentication_required, Access::Gate::AUTHENTICATION_MESSAGE
    assert_denied disabled_user, :authentication_required, Access::Gate::AUTHENTICATION_MESSAGE
    assert_denied organization, :organization_inactive, Access::Gate::ORGANIZATION_MESSAGE
    assert_denied organization_membership,
      :organization_membership_inactive,
      Access::Gate::ORGANIZATION_ACCESS_MESSAGE
  end

  test "the first failed factor wins" do
    @organization.update!(status: :suspended)
    Current.session = nil
    result = gate(product_key: "missing_product", feature_key: "missing_feature")

    assert_equal :authentication_required, result.reason_code
  end

  test "authentication requires a live unexpired session and current user state" do
    expired = gate(now: @session.expires_at + 1.second)

    switch_context(user: @user, membership: @membership)
    revoked_session = Current.session
    Session.where(id: revoked_session.id).delete_all
    revoked = gate

    switch_context(user: @user, membership: @membership)
    assert_predicate @user, :authentication_allowed?
    User.where(id: @user.id).update_all(disabled_at: Time.current)
    disabled_in_database = gate

    assert_denied expired, :authentication_required, Access::Gate::AUTHENTICATION_MESSAGE
    assert_predicate revoked_session, :persisted?
    assert_denied revoked, :authentication_required, Access::Gate::AUTHENTICATION_MESSAGE
    assert_predicate @user, :authentication_allowed?
    assert_denied disabled_in_database,
      :authentication_required,
      Access::Gate::AUTHENTICATION_MESSAGE
  end

  test "owner receives no product-data bypass but can pass after explicit assignment" do
    switch_context(user: @owner, membership: @owner_membership)

    missing_assignment = gate
    owner_product_membership = add_product_membership(@owner_membership)
    assign_role(owner_product_membership, @role)
    explicitly_assigned = gate

    assert_equal :product_membership_missing, missing_assignment.reason_code
    assert_predicate explicitly_assigned, :allowed?
  end

  test "billing organization role cannot receive product-data access" do
    billing_user = create_test_user(
      email_address: "gate-billing-#{SecureRandom.hex(6)}@example.test"
    )
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    billing_product_membership = add_product_membership(billing_membership)
    assign_role(billing_product_membership, @role)
    switch_context(user: billing_user, membership: billing_membership)

    result = gate

    assert_denied result,
      :organization_role_not_product_eligible,
      Access::Gate::PRODUCT_ACCESS_MESSAGE
  end

  test "entitlement and product membership failures precede billing role denial" do
    billing_user = create_test_user(
      email_address: "gate-billing-order-#{SecureRandom.hex(6)}@example.test"
    )
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    switch_context(user: billing_user, membership: billing_membership)

    missing_product_membership = gate
    unentitled_product = create_test_product(key: unique_catalog_key("billing_crm"))
    missing_entitlement = gate(product_key: unentitled_product.key)
    missing_feature = gate(feature_key: "missing_billing_feature")

    assert_denied missing_product_membership,
      :product_membership_missing,
      Access::Gate::PRODUCT_ACCESS_MESSAGE
    assert_denied missing_entitlement,
      :product_not_in_plan,
      Access::Gate::PRODUCT_PLAN_MESSAGE
    assert_denied missing_feature,
      :feature_not_found,
      Access::Gate::FEATURE_PLAN_MESSAGE
  end

  test "rejects an authorization context from another organization" do
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: @user,
      name: "Foreign Gate Organization",
      slug: "foreign-gate-organization-#{SecureRandom.hex(6)}"
    )
    foreign_context = AuthorizationContext.new(
      user: @user,
      organization: foreign_organization,
      membership: foreign_membership
    )

    result = gate(context: foreign_context)

    assert_denied result,
      :organization_context_invalid,
      Access::Gate::ORGANIZATION_MESSAGE
  end

  private
    def gate(
      context: AuthorizationContext.current,
      product_key: @product.key,
      permission_key: @permission.key,
      feature_key: nil,
      now: Time.current
    )
      Access::Gate.new(
        context: context,
        product_key: product_key,
        permission_key: permission_key,
        feature_key: feature_key,
        now: now
      ).call
    end

    def add_product_membership(membership)
      create_test_product_membership(
        organization_membership: membership,
        product: @product
      )
    end

    def assign_role(product_membership, product_role)
      create_test_product_membership_role(
        product_membership: product_membership,
        product_role: product_role
      )
    end

    def switch_context(user:, membership:)
      Current.session, = Session.issue_for!(
        user,
        ip_address: nil,
        user_agent: "Access gate test"
      )
      Current.organization = @organization
      Current.membership = membership
    end

    def suspend_current_organization_membership!
      Current.session, = Session.issue_for!(
        @owner,
        ip_address: nil,
        user_agent: "Access gate suspension test"
      )
      Current.membership = @owner_membership
      Organizations::Memberships::Remove.new(
        actor: @owner,
        membership_id: @membership.id
      ).call
      Current.session = @session
      Current.membership = @membership
    end

    def assert_denied(result, reason_code, message)
      assert_predicate result, :denied?
      assert_equal reason_code, result.reason_code
      assert_equal message, result.message
    end
end
