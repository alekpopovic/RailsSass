require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    founder = create_test_user(email_address: "policy-founder@example.test")
    @organization, @founder_membership = create_test_organization_with_owner(
      owner: founder,
      name: "Policy Organization",
      slug: "policy-organization"
    )
    @user = create_test_user(email_address: "policy-suspended-member@example.test")
  end

  test "role matrix grants only the organization capabilities assigned to each role" do
    expectations = {
      owner: {
        dashboard: true, products: true, pricing: true, members: true,
        settings: true, update: true, billing: true
      },
      admin: {
        dashboard: true, products: true, pricing: true, members: true,
        settings: true, update: true, billing: false
      },
      billing: {
        dashboard: true, products: true, pricing: true, members: false,
        settings: false, update: false, billing: true
      },
      member: {
        dashboard: true, products: true, pricing: true, members: false,
        settings: false, update: false, billing: false
      }
    }

    expectations.each_with_index do |(role, permissions), index|
      user = create_test_user(email_address: "policy-#{role}@example.test")
      organization, owner = create_test_organization_with_owner(
        owner: user,
        name: "#{role.to_s.humanize} Policy Organization",
        slug: "#{role}-policy-organization"
      )
      membership = if role == :owner
        owner
      else
        role_user = create_test_user(email_address: "policy-#{role}-member-#{index}@example.test")
        create_test_membership(organization: organization, user: role_user, role: role)
      end
      policy = policy_for(membership, organization)

      permissions.each do |action, allowed|
        assert_equal allowed, policy.public_send("#{action}?"), "expected #{role} #{action} to be #{allowed}"
      end
    end
  end

  test "denies suspended and inconsistent context" do
    membership = create_test_membership(
      organization: @organization,
      user: @user,
      role: :owner,
      status: :suspended
    )

    assert_not policy_for(membership).dashboard?

    other_owner = create_test_user(email_address: "other-policy-owner@example.test")
    other_organization, = create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Policy",
      slug: "other-policy"
    )
    context = AuthorizationContext.new(
      user: @user,
      organization: other_organization,
      membership: membership
    )

    assert_not OrganizationPolicy.new(context, @organization).dashboard?
  end

  test "membership policy scope fails closed and remains organization rooted" do
    owner = @founder_membership
    other_user = create_test_user(email_address: "other-policy-member@example.test")
    expected = create_test_membership(
      organization: @organization,
      user: other_user,
      role: :member
    )
    other_organization, other_membership = create_test_organization_with_owner(
      owner: other_user,
      name: "Scoped Other",
      slug: "scoped-other"
    )
    scope = OrganizationMembership.where(id: [ expected.id, other_membership.id ])

    resolved = OrganizationMembershipPolicy::Scope.new(context_for(owner), scope).resolve

    assert_equal [ expected ], resolved.to_a

    member_context = context_for(expected)
    assert_empty OrganizationMembershipPolicy::Scope.new(member_context, scope).resolve
  end

  private
    def policy_for(membership, record = @organization)
      OrganizationPolicy.new(context_for(membership), record)
    end

    def context_for(membership)
      AuthorizationContext.new(
        user: membership.user,
        organization: membership.organization,
        membership: membership
      )
    end
end
