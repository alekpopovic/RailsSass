require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationInvitationPolicyTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "invitation-policy-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(owner: @owner)
  end

  teardown do
    Current.reset
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
    context = acceptance_context_for(recipient)

    assert OrganizationInvitationPolicy.new(context, invitation).accept?

    wrong_user = create_test_user(email_address: "invitation-policy-wrong@example.test")
    wrong_context = acceptance_context_for(wrong_user)
    assert_not OrganizationInvitationPolicy.new(wrong_context, invitation).accept?

    context = acceptance_context_for(recipient)
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

  test "management and acceptance require a live database session" do
    management_context = context_for(@owner_membership)
    invitation = build_invitation(
      email_address: "invitation-policy-revoked@example.test",
      organization_role: :member
    )
    Session.where(id: Current.session.id).delete_all

    assert_not OrganizationInvitationPolicy.new(management_context, invitation).create?
    assert_empty OrganizationInvitationPolicy::Scope.new(
      management_context,
      OrganizationInvitation.all
    ).resolve

    recipient = create_test_user(email_address: invitation.email_address)
    invitation.save!
    acceptance_context = acceptance_context_for(recipient)
    Session.where(id: Current.session.id).delete_all

    assert_not OrganizationInvitationPolicy.new(acceptance_context, invitation).accept?
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
      establish_tenant_context(
        user: membership.user,
        organization: @organization,
        membership: membership
      )
      AuthorizationContext.current
    end

    def acceptance_context_for(user)
      Current.session, = Session.issue_for!(user, ip_address: nil, user_agent: "Invitation policy test")
      Current.organization = @organization
      Current.membership = nil
      AuthorizationContext.current
    end
end
