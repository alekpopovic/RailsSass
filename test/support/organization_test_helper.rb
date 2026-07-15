require_relative "authentication_test_helper"

module OrganizationTestHelper
  include AuthenticationTestHelper

  def create_test_organization(name: "Test Organization", slug: "test-organization", status: :active)
    Organization.create!(name: name, slug: slug, status: status)
  end

  def create_test_membership(organization:, user:, role:, status: :active, joined_at: Time.current)
    organization.organization_memberships.create!(
      user: user,
      role: role,
      status: status,
      joined_at: joined_at
    )
  end

  def create_test_organization_with_owner(owner:, **organization_attributes)
    organization = nil
    membership = nil

    Organization.transaction do
      organization = create_test_organization(**organization_attributes)
      membership = create_test_membership(
        organization: organization,
        user: owner,
        role: :owner
      )
    end

    [ organization, membership ]
  end

  def establish_tenant_context(user:, organization:, membership:)
    session_record, = Session.issue_for!(user, ip_address: nil, user_agent: "Minitest")
    Current.session = session_record
    Current.organization = organization
    Current.membership = membership
    session_record
  end
end
