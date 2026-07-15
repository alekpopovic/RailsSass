require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationMembersManagementRequestTest < ActionDispatch::IntegrationTest
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "member-management-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Member Management Organization",
      slug: "member-management-organization"
    )
    create_locator_for(@owner_membership)
    @member_user = create_test_user(email_address: "managed-member@example.test")
    @membership = create_test_membership(
      organization: @organization,
      user: @member_user,
      role: :member
    )
    create_locator_for(@membership)
    sign_in_as(@owner)
  end

  test "owner changes role suspends and reactivates a member through HTTP" do
    patch organization_member_path(
      organization_slug: @organization.slug,
      id: @membership.id
    ), params: { organization_membership: { role: "admin" } }

    assert_response :see_other
    assert_predicate @membership.reload, :admin?

    patch suspend_organization_member_path(
      organization_slug: @organization.slug,
      id: @membership.id
    )

    assert_response :see_other
    assert_predicate @membership.reload, :suspended?
    assert_not OrganizationAccessLocator.exists?(organization_membership_id: @membership.id)

    patch reactivate_organization_member_path(
      organization_slug: @organization.slug,
      id: @membership.id
    )

    assert_response :see_other
    assert_predicate @membership.reload, :active?
    assert OrganizationAccessLocator.exists?(organization_membership_id: @membership.id)
  end

  test "membership mutation IDs from another tenant return not found" do
    foreign_owner = create_test_user(email_address: "foreign-member-owner@example.test")
    foreign_organization, foreign_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Member Organization",
      slug: "foreign-member-organization"
    )

    patch organization_member_path(
      organization_slug: @organization.slug,
      id: foreign_membership.id
    ), params: { organization_membership: { role: "admin" } }
    assert_response :not_found

    patch suspend_organization_member_path(
      organization_slug: @organization.slug,
      id: foreign_membership.id
    )
    assert_response :not_found

    patch reactivate_organization_member_path(
      organization_slug: @organization.slug,
      id: foreign_membership.id
    )
    assert_response :not_found
    assert_predicate foreign_membership.reload, :active?
    assert_equal foreign_organization.id, foreign_membership.organization_id
  end

  test "last owner invariant is presented as an accessible error" do
    patch organization_member_path(
      organization_slug: @organization.slug,
      id: @owner_membership.id
    ), params: { organization_membership: { role: "member" } }

    assert_response :see_other
    follow_redirect!
    assert_response :success
    assert_select "[role='alert']", text: /active owner/i
    assert_predicate @owner_membership.reload, :owner?
  end

  test "an owner suspending self is redirected outside the tenant" do
    second_owner = create_test_user(email_address: "remaining-request-owner@example.test")
    second_owner_membership = create_test_membership(
      organization: @organization,
      user: second_owner,
      role: :owner
    )
    create_locator_for(second_owner_membership)

    patch suspend_organization_member_path(
      organization_slug: @organization.slug,
      id: @owner_membership.id
    )

    assert_response :see_other
    assert_redirected_to root_path
    assert_predicate @owner_membership.reload, :suspended?
    assert_not OrganizationAccessLocator.exists?(organization_membership_id: @owner_membership.id)
    assert_predicate second_owner_membership.reload, :active?
  end

  test "admin manages only member and admin targets through direct requests" do
    delete session_path
    admin = create_test_user(email_address: "member-request-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    create_locator_for(admin_membership)
    billing_user = create_test_user(email_address: "member-request-billing@example.test")
    billing_membership = create_test_membership(
      organization: @organization,
      user: billing_user,
      role: :billing
    )
    suspended_user = create_test_user(email_address: "member-request-suspended@example.test")
    suspended_membership = create_test_membership(
      organization: @organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )
    sign_in_as(admin)

    patch organization_member_path(
      organization_slug: @organization.slug,
      id: @membership.id
    ), params: { organization_membership: { role: "admin" } }
    assert_response :see_other
    assert_predicate @membership.reload, :admin?

    patch reactivate_organization_member_path(
      organization_slug: @organization.slug,
      id: suspended_membership.id
    )
    assert_response :see_other
    assert_predicate suspended_membership.reload, :active?

    [ @owner_membership, billing_membership ].each do |protected_membership|
      patch organization_member_path(
        organization_slug: @organization.slug,
        id: protected_membership.id
      ), params: { organization_membership: { role: "member" } }
      assert_response :forbidden

      patch suspend_organization_member_path(
        organization_slug: @organization.slug,
        id: protected_membership.id
      )
      assert_response :forbidden
    end

    patch organization_member_path(
      organization_slug: @organization.slug,
      id: @membership.id
    ), params: { organization_membership: { role: "owner" } }
    assert_response :forbidden
    assert_predicate @membership.reload, :admin?
  end

  test "billing and member actors cannot change suspend or reactivate memberships" do
    delete session_path
    suspended_user = create_test_user(email_address: "denied-reactivation-target@example.test")
    suspended_membership = create_test_membership(
      organization: @organization,
      user: suspended_user,
      role: :member,
      status: :suspended
    )

    %i[billing member].each do |role|
      actor = create_test_user(email_address: "denied-member-manager-#{role}@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      create_locator_for(actor_membership)
      sign_in_as(actor)

      patch organization_member_path(
        organization_slug: @organization.slug,
        id: @membership.id
      ), params: { organization_membership: { role: "admin" } }
      assert_response :forbidden

      patch suspend_organization_member_path(
        organization_slug: @organization.slug,
        id: @membership.id
      )
      assert_response :forbidden

      patch reactivate_organization_member_path(
        organization_slug: @organization.slug,
        id: suspended_membership.id
      )
      assert_response :forbidden

      delete session_path
    end

    assert_predicate @membership.reload, :active?
    assert_predicate suspended_membership.reload, :suspended?
  end

  private
    def create_locator_for(membership)
      OrganizationAccessLocator.find_or_create_by!(
        organization_membership: membership,
        user: membership.user,
        organization: membership.organization
      )
    end
end
