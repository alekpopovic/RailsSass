require "test_helper"
require_relative "../support/product_rbac_test_helper"

class ProductMembershipsRequestTest < ActionDispatch::IntegrationTest
  include ProductRbacTestHelper

  setup do
    suffix = SecureRandom.hex(6)
    @owner = create_test_user(email_address: "product-members-owner-#{suffix}@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Product Members #{suffix}",
      slug: "product-members-#{suffix}"
    )
    create_locator_for(@owner_membership)
    @member = create_test_user(
      name: "Assigned Product Member",
      email_address: "assigned-product-member-#{suffix}@example.test"
    )
    @organization_membership = create_test_membership(
      organization: @organization,
      user: @member,
      role: :member
    )
    create_locator_for(@organization_membership)
    @product = create_test_product(key: "product_members_#{suffix}", name: "Analytics")
    @plan = create_test_plan(key: "product_members_plan_#{suffix}", free: true)
    create_test_plan_product(plan: @plan, product: @product)
    @role = create_test_product_role(
      product: @product,
      key: "viewer",
      name: "Viewer"
    )
    sign_in_as(@owner)
  end

  test "owner manages the complete product member and system role lifecycle" do
    get members_path

    assert_response :success
    assert_select "h1", "Analytics members"
    assert_select "label", text: "Organization member"
    assert_select "option", text: /Assigned Product Member/
    assert_select "p", text: "No product members yet"

    assert_difference [
      -> { @organization.product_memberships.count },
      -> { @organization.audit_events.count }
    ], 1 do
      post members_path, params: {
        product_membership: { organization_membership_id: @organization_membership.id }
      }
    end
    assert_response :see_other
    product_membership = @organization.product_memberships.find_by!(
      organization_membership_id: @organization_membership.id,
      product_id: @product.id
    )

    assert_difference [
      -> { product_membership.product_membership_roles.count },
      -> { @organization.audit_events.count }
    ], 1 do
      post assign_role_path(product_membership), params: { role_key: @role.key }
    end
    assert_response :see_other

    patch suspend_path(product_membership)
    assert_response :see_other
    assert_predicate product_membership.reload, :suspended?

    patch reactivate_path(product_membership)
    assert_response :see_other
    assert_predicate product_membership.reload, :active?

    assert_difference -> { product_membership.product_membership_roles.count }, -1 do
      assert_difference -> { @organization.audit_events.count }, 1 do
        delete unassign_role_path(product_membership), params: { role_key: @role.key }
      end
    end
    assert_response :see_other

    assert_difference -> { @organization.product_memberships.count }, -1 do
      delete member_path(product_membership)
    end
    assert_response :see_other
    assert_equal %w[
      product.membership.created
      product.membership.role_assigned
      product.membership.suspended
      product.membership.reactivated
      product.membership.role_unassigned
      product.membership.removed
    ], @organization.audit_events.order(:id).pluck(:action)
  end

  test "index contains only current organization product members" do
    local_product_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: @product
    )
    foreign_owner = create_test_user(email_address: "hidden-product-member@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Hidden Product Organization",
      slug: "hidden-product-organization"
    )
    create_test_product_membership(
      organization_membership: foreign_membership,
      product: @product
    )

    get members_path

    assert_response :success
    assert_select "li", text: /Assigned Product Member/
    assert_no_match "hidden-product-member@example.test", response.body
    assert_equal @organization.id, local_product_membership.organization_id
    assert_not_equal @organization.id, foreign_organization.id
  end

  test "member role cannot list or mutate product assignments through direct requests" do
    product_membership = create_test_product_membership(
      organization_membership: @owner_membership,
      product: @product
    )
    create_test_product_membership_role(
      product_membership: product_membership,
      product_role: @role
    )
    delete session_path
    sign_in_as(@member)

    get members_path
    assert_response :forbidden

    mutations = [
      -> { post members_path, params: {
        product_membership: { organization_membership_id: @organization_membership.id }
      } },
      -> { post assign_role_path(product_membership), params: { role_key: @role.key } },
      -> { delete unassign_role_path(product_membership), params: { role_key: @role.key } },
      -> { patch suspend_path(product_membership) },
      -> { patch reactivate_path(product_membership) },
      -> { delete member_path(product_membership) }
    ]

    assert_no_difference [
      -> { @organization.product_memberships.count },
      -> { ProductMembershipRole.count },
      -> { @organization.audit_events.count }
    ] do
      mutations.each do |request|
        request.call
        assert_response :forbidden
      end
    end
  end

  test "foreign membership and product membership identifiers return not found" do
    foreign_owner = create_test_user(email_address: "foreign-product-owner@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Product Members",
      slug: "foreign-product-members"
    )
    foreign_product_membership = create_test_product_membership(
      organization_membership: foreign_membership,
      product: @product
    )

    post members_path, params: {
      product_membership: { organization_membership_id: foreign_membership.id }
    }
    assert_response :not_found

    [
      -> { post assign_role_path(foreign_product_membership), params: { role_key: @role.key } },
      -> { delete unassign_role_path(foreign_product_membership), params: { role_key: @role.key } },
      -> { patch suspend_path(foreign_product_membership) },
      -> { patch reactivate_path(foreign_product_membership) },
      -> { delete member_path(foreign_product_membership) }
    ].each do |request|
      request.call
      assert_response :not_found
    end

    assert_predicate foreign_product_membership.reload, :active?
    assert_equal foreign_organization.id, foreign_product_membership.organization_id
  end

  test "role assignment accepts only an active system role for the routed product" do
    product_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: @product
    )
    organization_role = create_test_product_role(
      product: @product,
      organization: @organization,
      key: "organization_viewer"
    )
    inactive_role = create_test_product_role(
      product: @product,
      key: "inactive_viewer",
      active: false
    )
    other_product = create_test_product(key: "other_product_#{SecureRandom.hex(6)}")
    other_role = create_test_product_role(
      product: other_product,
      key: "other_viewer"
    )

    [ organization_role, inactive_role, other_role ].each do |role|
      assert_no_difference [
        -> { product_membership.product_membership_roles.count },
        -> { @organization.audit_events.count }
      ] do
        post assign_role_path(product_membership), params: { role_key: role.key }
        assert_response :not_found
      end
    end
  end

  test "an unentitled product cannot expose or create product assignments" do
    unentitled_product = create_test_product(key: "unentitled_#{SecureRandom.hex(6)}")
    unentitled_members_path = organization_product_members_path(
      organization_slug: @organization.slug,
      product_key: unentitled_product.key
    )

    get unentitled_members_path
    assert_response :forbidden

    assert_no_difference -> { @organization.product_memberships.count } do
      post unentitled_members_path, params: {
        product_membership: { organization_membership_id: @organization_membership.id }
      }
      assert_response :forbidden
    end
  end

  test "a suspended duplicate is rendered as an accessible validation error" do
    product_membership = create_test_product_membership(
      organization_membership: @organization_membership,
      product: @product
    )
    @organization.product_memberships.where(id: product_membership.id).update_all(
      status: "suspended",
      updated_at: Time.current
    )

    post members_path, params: {
      product_membership: { organization_membership_id: @organization_membership.id }
    }

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /reactivated/i
    assert_predicate product_membership.reload, :suspended?
  end

  test "seat usage is visible and server-side add and reactivate stay blocked at capacity" do
    seat_feature = create_test_product_feature(
      product: @product,
      key: Entitlements::Usage::SEAT_FEATURE_KEY,
      name: "Product seats",
      kind: :limit
    )
    create_test_entitlement(
      plan_product: PlanProduct.find_by!(plan: @plan, product: @product),
      product_feature: seat_feature,
      limit_value: 1
    )
    owner_product_membership = create_test_product_membership(
      organization_membership: @owner_membership,
      product: @product
    )

    get members_path

    assert_response :success
    assert_select "[data-entitlement-usage='seat_limit']", text: /1 of 1 seats used/
    assert_select "form[action=?]", members_path, count: 0

    assert_no_difference -> { @organization.product_memberships.count } do
      post members_path, params: {
        product_membership: { organization_membership_id: @organization_membership.id }
      }
    end
    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /plan limit has been reached/i

    patch suspend_path(owner_product_membership)
    assert_response :see_other
    assert_predicate owner_product_membership.reload, :suspended?

    post members_path, params: {
      product_membership: { organization_membership_id: @organization_membership.id }
    }
    assert_response :see_other
    assert_predicate @organization.product_memberships.find_by!(
      organization_membership: @organization_membership,
      product: @product
    ), :active?

    patch reactivate_path(owner_product_membership)
    assert_response :see_other
    assert_predicate owner_product_membership.reload, :suspended?
  end

  private
    def create_locator_for(membership)
      OrganizationAccessLocator.create!(
        organization: membership.organization,
        organization_membership: membership,
        user: membership.user
      )
    end

    def members_path
      organization_product_members_path(
        organization_slug: @organization.slug,
        product_key: @product.key
      )
    end

    def member_path(product_membership)
      organization_product_member_path(
        organization_slug: @organization.slug,
        product_key: @product.key,
        id: product_membership.id
      )
    end

    def suspend_path(product_membership)
      suspend_organization_product_member_path(
        organization_slug: @organization.slug,
        product_key: @product.key,
        id: product_membership.id
      )
    end

    def reactivate_path(product_membership)
      reactivate_organization_product_member_path(
        organization_slug: @organization.slug,
        product_key: @product.key,
        id: product_membership.id
      )
    end

    def assign_role_path(product_membership)
      assign_role_organization_product_member_path(
        organization_slug: @organization.slug,
        product_key: @product.key,
        id: product_membership.id
      )
    end

    def unassign_role_path(product_membership)
      unassign_role_organization_product_member_path(
        organization_slug: @organization.slug,
        product_key: @product.key,
        id: product_membership.id
      )
    end
end
