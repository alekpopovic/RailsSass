require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationInvitationPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "invitation-policy-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(owner: @owner)
  end

  test "management predicates enforce owner and admin invitation roles" do
    owner_expectations = { owner: true, admin: true, billing: true, member: true }
    assert_role_expectations(@owner_membership, owner_expectations)

    admin = create_test_user(email_address: "invitation-policy-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    assert_role_expectations(
      admin_membership,
      owner: false,
      admin: true,
      billing: false,
      member: true
    )

    %i[billing member].each do |role|
      user = create_test_user(email_address: "invitation-policy-#{role}@example.test")
      membership = create_test_membership(
        organization: @organization,
        user: user,
        role: role
      )
      assert_role_expectations(
        membership,
        owner: false,
        admin: false,
        billing: false,
        member: false
      )
    end
  end

  test "acceptance requires matching authenticated email and an active invitation" do
    recipient = create_test_user(email_address: "invitation-policy-recipient@example.test")
    invitation = build_invitation(email_address: recipient.email_address, organization_role: :member)
    invitation.save!
    context = AuthorizationContext.new(
      user: recipient,
      organization: @organization,
      membership: nil
    )

    assert OrganizationInvitationPolicy.new(context, invitation).accept?

    wrong_user = create_test_user(email_address: "invitation-policy-wrong@example.test")
    wrong_context = AuthorizationContext.new(
      user: wrong_user,
      organization: @organization,
      membership: nil
    )
    assert_not OrganizationInvitationPolicy.new(wrong_context, invitation).accept?

    OrganizationInvitation.where(id: invitation.id).update_all(
      status: "revoked",
      revoked_at: Time.current
    )
    assert_not OrganizationInvitationPolicy.new(context, invitation.reload).accept?
  end

  test "admin invitation scope excludes owner and billing grants" do
    admin = create_test_user(email_address: "invitation-scope-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    invitations = %i[owner admin billing member].map do |role|
      build_invitation(
        email_address: "invitation-scope-#{role}@example.test",
        organization_role: role
      ).tap(&:save!)
    end
    scope = @organization.organization_invitations.where(id: invitations.map(&:id))

    resolved = OrganizationInvitationPolicy::Scope.new(
      context_for(admin_membership),
      scope
    ).resolve

    assert_equal %w[admin member], resolved.order(:organization_role).pluck(:organization_role)
  end

  private
    def assert_role_expectations(membership, expectations)
      expectations.each do |role, expected|
        invitation = build_invitation(
          email_address: "policy-#{membership.id}-#{role}@example.test",
          organization_role: role
        )
        policy = OrganizationInvitationPolicy.new(context_for(membership), invitation)

        assert_equal expected, policy.create?, "expected #{membership.role} to manage #{role} invitation"
      end
    end

    def build_invitation(email_address:, organization_role:)
      @organization.organization_invitations.build(
        inviter: @owner,
        email_address: email_address,
        organization_role: organization_role,
        token_digest: OrganizationInvitation.digest_token(SecureRandom.urlsafe_base64(32)),
        expires_at: 7.days.from_now
      )
    end

    def context_for(membership)
      AuthorizationContext.new(
        user: membership.user,
        organization: @organization,
        membership: membership
      )
    end
end
