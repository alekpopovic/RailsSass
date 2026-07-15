require "test_helper"
require_relative "../support/organization_test_helper"

class TenantContextRequestTest < ActionDispatch::IntegrationTest
  include OrganizationTestHelper

  test "tenant route helpers require and preserve an explicit slug" do
    assert_equal "/o/example-tenant/dashboard",
      organization_dashboard_path(organization_slug: "example-tenant")
    assert_equal "/o/example-tenant/members",
      organization_members_path(organization_slug: "example-tenant")
    assert_equal "/o/example-tenant/settings",
      organization_settings_path(organization_slug: "example-tenant")
    assert_equal "/o/example-tenant/billing",
      organization_billing_path(organization_slug: "example-tenant")

    assert_raises(ActionController::UrlGenerationError) do
      organization_dashboard_path
    end
  end

  test "authentication returns to the tenant path and tenant context is still revalidated" do
    user = create_test_user(email_address: "tenant-return@example.test")
    organization, = create_tenant_for(
      user: user,
      name: "Return Tenant",
      slug: "return-tenant"
    )
    tenant_path = organization_dashboard_path(organization_slug: organization.slug)

    get tenant_path
    assert_redirected_to new_session_path

    post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }
    assert_redirected_to tenant_path

    follow_redirect!
    assert_response :success
    assert_select "h1", "Return Tenant"
  end

  test "tenant routes authenticate and establish only an active authoritative membership" do
    user = create_test_user(email_address: "tenant-owner@example.test")
    organization, membership = create_tenant_for(
      user: user,
      role: :member,
      name: "Tenant One",
      slug: "tenant-one"
    )
    sign_in_as(user)

    get organization_dashboard_path(organization_slug: " Tenant One ")

    assert_response :success
    assert_select "h1", "Tenant One"
    assert_equal organization.id, request.session[:organization_id]
    assert_nil Current.organization
    assert_nil Current.membership

    OrganizationMembership.where(id: membership.id).update_all(status: "suspended")

    get organization_dashboard_path(organization_slug: organization.slug)

    assert_response :not_found
    assert_nil request.session[:organization_id]
    assert_select "title", "Page not found (404)"
    assert_no_match organization.public_id, response.body
  end

  test "a URL slug and stale locator never prove membership" do
    owner = create_test_user(email_address: "foreign-owner@example.test")
    foreign_organization, = create_tenant_for(
      user: owner,
      name: "Confidential Foreign Tenant",
      slug: "foreign-tenant"
    )
    intruder = create_test_user(email_address: "tenant-intruder@example.test")
    sign_in_as(intruder)

    get organization_dashboard_path(organization_slug: foreign_organization.slug)

    assert_response :not_found
    assert_select "title", "Page not found (404)"
    assert_no_match "Confidential Foreign Tenant", response.body

    get organization_dashboard_path(organization_slug: "unknown-tenant")

    assert_response :not_found
    assert_select "title", "Page not found (404)"
    assert_no_match "unknown-tenant", response.body
  end

  test "suspended organizations consistently return not found" do
    user = create_test_user(email_address: "suspended-tenant-owner@example.test")
    organization, = create_tenant_for(
      user: user,
      name: "Suspended Tenant",
      slug: "suspended-tenant"
    )
    Organization.where(id: organization.id).update_all(status: "suspended")
    sign_in_as(user)

    get organization_dashboard_path(organization_slug: organization.slug)

    assert_response :not_found
    assert_nil request.session[:organization_id]
  end

  test "organization switcher changes only after the target tenant is revalidated" do
    user = create_test_user(email_address: "switcher-owner@example.test")
    first, = create_tenant_for(user: user, name: "First Tenant", slug: "first-tenant")
    second, = create_tenant_for(user: user, name: "Second Tenant", slug: "second-tenant")
    sign_in_as(user)

    get organization_dashboard_path(organization_slug: first.slug)

    assert_response :success
    assert_select "summary", text: /First Tenant/
    assert_select "a[href=?]", organization_dashboard_path(organization_slug: second.slug), "Second Tenant"
    assert_equal first.id, request.session[:organization_id]

    get organization_dashboard_path(organization_slug: second.slug)

    assert_response :success
    assert_select "h1", "Second Tenant"
    assert_equal second.id, request.session[:organization_id]
  end

  test "organization role matrix is enforced by the server" do
    member = create_test_user(email_address: "tenant-member@example.test")
    organization, = create_tenant_for(
      user: member,
      role: :member,
      name: "Member Tenant",
      slug: "member-tenant"
    )
    sign_in_as(member)

    get organization_dashboard_path(organization_slug: organization.slug)
    assert_response :success

    get organization_members_path(organization_slug: organization.slug)
    assert_generic_forbidden

    get organization_settings_path(organization_slug: organization.slug)
    assert_generic_forbidden

    get organization_billing_path(organization_slug: organization.slug)
    assert_generic_forbidden
    assert_nil Current.organization
    assert_nil Current.membership
  end

  test "admin and billing roles receive only their assigned tenant screens" do
    admin = create_test_user(email_address: "tenant-admin@example.test")
    admin_organization, = create_tenant_for(
      user: admin,
      role: :admin,
      name: "Admin Tenant",
      slug: "admin-tenant"
    )
    sign_in_as(admin)

    get organization_members_path(organization_slug: admin_organization.slug)
    assert_response :success
    get organization_settings_path(organization_slug: admin_organization.slug)
    assert_response :success
    get organization_billing_path(organization_slug: admin_organization.slug)
    assert_generic_forbidden

    delete session_path

    billing = create_test_user(email_address: "tenant-billing@example.test")
    billing_organization, = create_tenant_for(
      user: billing,
      role: :billing,
      name: "Billing Tenant",
      slug: "billing-tenant"
    )
    sign_in_as(billing)

    get organization_billing_path(organization_slug: billing_organization.slug)
    assert_response :success
    get organization_members_path(organization_slug: billing_organization.slug)
    assert_generic_forbidden
  end

  test "members collection is policy scoped through the current organization" do
    admin = create_test_user(email_address: "scoped-admin@example.test")
    organization, = create_tenant_for(
      user: admin,
      role: :admin,
      name: "Scoped Tenant",
      slug: "scoped-tenant"
    )
    visible_user = create_test_user(name: "Visible Member", email_address: "visible-member@example.test")
    visible_membership = create_test_membership(
      organization: organization,
      user: visible_user,
      role: :member
    )
    create_locator_for(visible_membership)

    foreign_owner = create_test_user(name: "Hidden Foreign Member", email_address: "hidden-member@example.test")
    create_tenant_for(
      user: foreign_owner,
      name: "Hidden Tenant",
      slug: "hidden-tenant"
    )
    sign_in_as(admin)

    get organization_members_path(organization_slug: organization.slug)

    assert_response :success
    assert_select "li", text: /Visible Member/
    assert_no_match "Hidden Foreign Member", response.body
  end

  private
    def create_tenant_for(user:, name:, slug:, role: :owner)
      if role == :owner
        organization, membership = create_test_organization_with_owner(
          owner: user,
          name: name,
          slug: slug
        )
      else
        owner = create_test_user(email_address: "owner-#{slug}@example.test")
        organization, owner_membership = create_test_organization_with_owner(
          owner: owner,
          name: name,
          slug: slug
        )
        create_locator_for(owner_membership)
        membership = create_test_membership(
          organization: organization,
          user: user,
          role: role
        )
      end

      create_locator_for(membership)
      [ organization, membership ]
    end

    def create_locator_for(membership)
      OrganizationAccessLocator.create!(
        organization_membership: membership,
        organization: membership.organization,
        user: membership.user
      )
    end

    def assert_generic_forbidden
      assert_response :forbidden
      assert_select "title", "Forbidden (403)"
      assert_no_match(/Pundit|NotAuthorized|policy/, response.body)
    end
end
