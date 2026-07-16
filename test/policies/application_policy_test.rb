require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ApplicationPolicyTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  class ProductDataPolicy < ApplicationPolicy
    PRODUCT_KEY = "application_policy_product"
    PERMISSION_KEY = "records.view"

    def show?
      record_owned_by_current_organization? && product_access_allowed?(
        product_key: PRODUCT_KEY,
        permission_key: PERMISSION_KEY
      )
    end

    class Scope < ApplicationPolicy::Scope
      def resolve
        tenant_scope = Current.organization&.product_memberships&.merge(scope) || scope.none
        return tenant_scope.none unless product_access_allowed?(
          product_key: ProductDataPolicy::PRODUCT_KEY,
          permission_key: ProductDataPolicy::PERMISSION_KEY
        )

        tenant_scope.joins(:product).where(products: { key: ProductDataPolicy::PRODUCT_KEY })
      end
    end
  end

  test "denies every base action" do
    policy = ApplicationPolicy.new(Object.new, Object.new)

    %i[index? show? create? new? update? edit? destroy?].each do |query|
      assert_not policy.public_send(query), "expected #{query} to deny access"
    end
  end

  test "requires every policy scope to define resolve" do
    error = assert_raises(NoMethodError) do
      ApplicationPolicy::Scope.new(Object.new, Object.new).resolve
    end

    assert_match "Define #resolve", error.message
  end

  test "application controller includes Pundit authorization" do
    assert_includes ApplicationController.ancestors, Pundit::Authorization
  end

  test "tenant controllers verify record authorization and collection scoping" do
    base_after_actions = after_action_filters(Organizations::BaseController)
    members_after_actions = after_action_filters(Organizations::MembersController)

    assert_includes base_after_actions, :verify_authorized
    assert_includes members_after_actions, :verify_policy_scoped
  end

  test "extracts all tenant authorization inputs from the Pundit context" do
    user = Object.new
    organization = Object.new
    membership = Object.new
    context = AuthorizationContext.new(
      user: user,
      organization: organization,
      membership: membership
    )
    policy = ApplicationPolicy.new(context, Object.new)

    assert_same context, policy.context
    assert_same user, policy.user
    assert_same organization, policy.organization
    assert_same membership, policy.membership
  end

  test "builds an immutable authorization context from Current" do
    user = Object.new
    organization = Object.new
    membership = Object.new
    session = Struct.new(:user).new(user)
    Current.session = session
    Current.organization = organization
    Current.membership = membership

    context = AuthorizationContext.current

    assert_same user, context.user
    assert_same organization, context.organization
    assert_same membership, context.membership
    assert_predicate context, :frozen?
  ensure
    Current.reset
  end

  test "policy and scope product helpers delegate to the same Access gate" do
    user = create_test_user(email_address: "application-policy-gate@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: user,
      name: "Application Policy Gate",
      slug: "application-policy-gate"
    )
    establish_tenant_context(user: user, organization: organization, membership: membership)
    product = create_test_product
    plan = create_test_plan(free: true)
    create_test_plan_product(plan: plan, product: product)
    permission = create_test_product_permission(product: product, key: "records.view")
    role = create_test_product_role(product: product)
    create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )
    product_membership = create_test_product_membership(
      organization_membership: membership,
      product: product
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: role
    )
    context = AuthorizationContext.current
    policy = ApplicationPolicy.new(context, Object.new)
    policy_scope = ApplicationPolicy::Scope.new(context, Object.new)

    policy_result = policy.send(
      :product_access_decision,
      product_key: product.key,
      permission_key: permission.key
    )
    scope_allowed = policy_scope.send(
      :product_access_allowed?,
      product_key: product.key,
      permission_key: permission.key
    )

    assert_instance_of Access::Decision, policy_result
    assert_predicate policy_result, :allowed?
    assert scope_allowed
  ensure
    Current.reset
  end

  test "a concrete product policy combines the gate with record and scope tenant ownership" do
    user = create_test_user(email_address: "application-policy-product@example.test")
    organization, membership = create_test_organization_with_owner(
      owner: user,
      name: "Application Product Policy",
      slug: "application-product-policy"
    )
    establish_tenant_context(user: user, organization: organization, membership: membership)
    product = create_test_product(key: ProductDataPolicy::PRODUCT_KEY)
    plan = create_test_plan(free: true)
    create_test_plan_product(plan: plan, product: product)
    permission = create_test_product_permission(
      product: product,
      key: ProductDataPolicy::PERMISSION_KEY
    )
    role = create_test_product_role(product: product)
    mapping = create_test_product_role_permission(
      product_role: role,
      product_permission: permission
    )
    local_record = create_test_product_membership(
      organization_membership: membership,
      product: product
    )
    create_test_product_membership_role(
      product_membership: local_record,
      product_role: role
    )
    foreign_user = create_test_user(email_address: "application-policy-foreign@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_user,
      name: "Application Foreign Policy",
      slug: "application-foreign-policy"
    )
    foreign_record = create_test_product_membership(
      organization_membership: foreign_membership,
      product: product
    )
    context = AuthorizationContext.current
    supplied_scope = ProductMembership.where(id: [ local_record.id, foreign_record.id ])

    assert ProductDataPolicy.new(context, local_record).show?
    assert_not ProductDataPolicy.new(context, foreign_record).show?
    assert_equal [ local_record ], ProductDataPolicy::Scope.new(context, supplied_scope).resolve.to_a

    mapping.destroy!

    assert_not ProductDataPolicy.new(context, local_record).show?
    assert_empty ProductDataPolicy::Scope.new(context, supplied_scope).resolve
    assert_equal foreign_organization.id, foreign_record.organization_id
  ensure
    Current.reset
  end

  private
    def after_action_filters(controller)
      controller._process_action_callbacks
        .select { |callback| callback.kind == :after }
        .map(&:filter)
    end
end
