require "test_helper"
require_relative "../../support/organization_test_helper"

class Organizations::TenantIsolationTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  teardown do
    Current.reset
  end

  test "a foreign membership cannot be read changed or removed through the current tenant" do
    actor = create_test_user(email_address: "isolation-actor@example.test")
    organization, actor_membership = create_test_organization_with_owner(
      owner: actor,
      name: "Isolation Tenant",
      slug: "isolation-tenant"
    )
    foreign_owner = create_test_user(email_address: "isolation-foreign-owner@example.test")
    foreign_organization, = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Isolation Tenant",
      slug: "foreign-isolation-tenant"
    )
    foreign_user = create_test_user(email_address: "isolation-foreign-member@example.test")
    foreign_membership = create_test_membership(
      organization: foreign_organization,
      user: foreign_user,
      role: :member
    )
    establish_tenant_context(
      user: actor,
      organization: organization,
      membership: actor_membership
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      Current.organization.organization_memberships.find(foreign_membership.id)
    end

    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Memberships::ChangeRole.new(
        actor: actor,
        membership_id: foreign_membership.id,
        role: :admin
      ).call
    end

    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Memberships::Remove.new(
        actor: actor,
        membership_id: foreign_membership.id
      ).call
    end

    assert_predicate foreign_membership.reload, :member?
    assert_predicate foreign_membership, :active?
  end
end
