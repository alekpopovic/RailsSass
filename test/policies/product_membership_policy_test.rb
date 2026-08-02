require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductMembershipPolicyTest < ActiveSupport::TestCase
  include ProductRbacTestHelper

  setup do
    @owner = create_test_user(email_address: "product-policy-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Product Policy Organization",
      slug: "product-policy-organization"
    )
    @member = create_test_user(email_address: "product-policy-member@example.test")
    @organization_membership = create_test_membership(
      organization: @organization,
      user: @member,
      role: :member
    )
    @product = create_test_product(key: "product_policy_analytics")
    @free_plan = create_test_plan(
      key: "product_policy_free",
      name: "Product Policy Free",
      free: true
    )
    create_test_plan_product(plan: @free_plan, product: @product)
    @product_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: @product
    )

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    @context = authorization_context_for(@owner_membership)
  end

  teardown do
    Current.reset
  end

  test "owner and admin can manage an entitled product without their own product membership" do
    assert_nil @organization.product_memberships.find_by(
      organization_membership_id: @owner_membership.id,
      product_id: @product.id
    )
    assert ProductMembershipPolicy.new(@context, ProductMembership).index?
    assert_management_actions(@context, allowed: true)

    admin = create_test_user(email_address: "product-policy-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    establish_tenant_context(
      user: admin,
      organization: @organization,
      membership: admin_membership
    )

    assert_management_actions(authorization_context_for(admin_membership), allowed: true)
  end

  test "billing and member organization roles cannot manage product memberships" do
    %i[billing member].each do |role|
      user = create_test_user(email_address: "product-policy-#{role}-actor@example.test")
      organization_membership = create_test_membership(
        organization: @organization,
        user: user,
        role: role
      )
      establish_tenant_context(
        user: user,
        organization: @organization,
        membership: organization_membership
      )

      assert_management_actions(
        authorization_context_for(organization_membership),
        allowed: false
      )
      assert_not ProductMembershipPolicy.new(
        authorization_context_for(organization_membership),
        ProductMembership
      ).index?
    end
  end

  test "action predicates follow product membership lifecycle state" do
    active_policy = policy_for(@context)

    assert active_policy.show?
    assert active_policy.update?
    assert active_policy.assign_role?
    assert active_policy.unassign_role?
    assert active_policy.suspend?
    assert_not active_policy.reactivate?
    assert active_policy.destroy?

    suspended_membership = Access::ProductMemberships::Suspend.new(
      product_membership_id: @product_membership.id,
      actor: @owner
    ).call
    suspended_policy = policy_for(@context, suspended_membership)

    assert suspended_policy.show?
    assert suspended_policy.update?
    assert_not suspended_policy.assign_role?
    assert suspended_policy.unassign_role?
    assert_not suspended_policy.suspend?
    assert suspended_policy.reactivate?
    assert suspended_policy.destroy?
  end

  test "create requires a new same-tenant membership for an entitled product" do
    another_user = create_test_user(email_address: "product-policy-new-member@example.test")
    another_membership = create_test_membership(
      organization: @organization,
      user: another_user,
      role: :member
    )
    new_product_membership = @organization.product_memberships.new(
      organization_membership: another_membership,
      product: @product
    )
    policy = policy_for(@context, new_product_membership)

    assert policy.create?
    assert policy.new?
    assert_not policy.show?
  end

  test "product-scoped index requires entitlement for the requested product" do
    scoped_record = @organization.product_memberships.new(product: @product)

    assert ProductMembershipPolicy.new(@context, scoped_record).index?

    unentitled_product = create_test_product(key: "product_policy_index_crm")
    unentitled_record = @organization.product_memberships.new(product: unentitled_product)

    assert_not ProductMembershipPolicy.new(@context, unentitled_record).index?
  end

  test "create rejects foreign and suspended target memberships" do
    foreign_owner = create_test_user(email_address: "product-policy-create-foreign@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Product Policy Create Foreign",
      slug: "product-policy-create-foreign"
    )
    foreign_target = @organization.product_memberships.new(
      organization_membership: foreign_membership,
      product: @product
    )
    suspended_user = create_test_user(
      email_address: "product-policy-create-suspended@example.test"
    )
    suspended_membership = create_test_membership(
      organization: @organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    suspended_target = @organization.product_memberships.new(
      organization_membership: suspended_membership,
      product: @product
    )

    assert_not policy_for(@context, foreign_target).create?
    assert_not policy_for(@context, suspended_target).create?
    assert_equal foreign_organization.id, foreign_membership.organization_id
  end

  test "granting and reactivation require an active catalog product" do
    @product.update!(active: false)
    active_policy = policy_for(@context)

    assert active_policy.show?
    assert_not active_policy.assign_role?
    assert active_policy.suspend?
    assert active_policy.destroy?

    suspended_product_membership = Access::ProductMemberships::Suspend.new(
      product_membership_id: @product_membership.id,
      actor: @owner
    ).call

    assert_not policy_for(@context, suspended_product_membership).reactivate?
  end

  test "management requires a live database session" do
    session = Current.session
    Session.where(id: session.id).delete_all

    assert_predicate session, :persisted?
    assert_not policy_for(@context).show?
  end

  test "management fails closed for suspended membership, disabled user, organization, and missing plan" do
    admin = create_test_user(email_address: "product-policy-suspended-admin@example.test")
    suspended_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin,
      status: :suspended
    )
    establish_tenant_context(
      user: admin,
      organization: @organization,
      membership: suspended_membership
    )
    assert_not policy_for(authorization_context_for(suspended_membership)).show?

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    @owner.update!(disabled_at: Time.current)
    assert_not policy_for(@context).show?

    @owner.update!(disabled_at: nil)
    @organization.update!(status: :suspended)
    assert_not policy_for(@context).show?

    @organization.update!(status: :active)
    @free_plan.update!(active: false)
    assert_not policy_for(@context).show?
    assert_not ProductMembershipPolicy.new(@context, ProductMembership).index?
  end

  test "an unentitled product and a foreign product membership are denied" do
    unentitled_product = create_test_product(key: "product_policy_crm")
    unentitled_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: unentitled_product
    )
    assert_not policy_for(@context, unentitled_membership).show?

    foreign_owner = create_test_user(email_address: "product-policy-foreign-owner@example.test")
    foreign_organization, foreign_owner_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Product Policy Organization",
      slug: "foreign-product-policy-organization"
    )
    foreign_member = create_test_user(email_address: "product-policy-foreign-member@example.test")
    foreign_organization_membership = create_test_membership(
      organization: foreign_organization,
      user: foreign_member,
      role: :member
    )
    foreign_product_membership = create_test_product_membership(
      organization_membership: foreign_organization_membership,
      product: @product
    )

    assert_not policy_for(@context, foreign_product_membership).show?
    assert_equal foreign_organization.id, foreign_owner_membership.organization_id
  end

  test "scope starts from the current organization, honors the supplied scope, and keeps entitled products" do
    omitted_user = create_test_user(email_address: "product-policy-omitted@example.test")
    omitted_membership = create_test_membership(
      organization: @organization,
      user: omitted_user,
      role: :member
    )
    omitted_product_membership = create_test_product_membership(
      organization_membership: omitted_membership,
      product: @product
    )
    unentitled_product = create_test_product(key: "product_policy_scope_crm")
    unentitled_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: unentitled_product
    )

    foreign_owner = create_test_user(email_address: "product-policy-scope-foreign@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Policy Scope",
      slug: "foreign-policy-scope"
    )
    foreign_product_membership = create_test_product_membership(
      organization_membership: foreign_membership,
      product: @product
    )
    supplied_scope = ProductMembership.where(
      id: [ @product_membership.id, unentitled_membership.id, foreign_product_membership.id ]
    )

    resolved = ProductMembershipPolicy::Scope.new(@context, supplied_scope).resolve

    assert_equal [ @product_membership ], resolved.to_a
    assert_not_includes resolved, omitted_product_membership
  end

  test "scope returns none without an active owner or admin context or an effective plan" do
    member_context = authorization_context_for(@organization_membership)
    establish_tenant_context(
      user: @member,
      organization: @organization,
      membership: @organization_membership
    )

    assert_empty ProductMembershipPolicy::Scope.new(
      member_context,
      ProductMembership.all
    ).resolve

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    @free_plan.update!(active: false)

    assert_empty ProductMembershipPolicy::Scope.new(
      @context,
      ProductMembership.all
    ).resolve
  end

  private
    def policy_for(context, record = @product_membership)
      ProductMembershipPolicy.new(context, record)
    end

    def authorization_context_for(organization_membership)
      AuthorizationContext.new(
        user: organization_membership.user,
        organization: organization_membership.organization,
        membership: organization_membership
      )
    end

    def assert_management_actions(context, allowed:)
      policy = policy_for(context)

      %i[show? update? assign_role? unassign_role? suspend? destroy?].each do |query|
        assert_equal allowed, policy.public_send(query), "expected #{query} to be #{allowed}"
      end
    end
end
