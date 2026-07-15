require "test_helper"
require_relative "../../../support/organization_test_helper"

class Organizations::Invitations::LifecycleTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "invitation-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(
      owner: @owner,
      name: "Invitation Organization",
      slug: "invitation-organization"
    )
    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
  end

  teardown do
    travel_back
    Current.reset
  end

  test "create normalizes email stores only the digest and keeps an active duplicate unchanged" do
    result = nil

    assert_difference -> { OrganizationInvitation.count }, 1 do
      assert_difference -> { AuditEvent.where(action: "organization.invitation.created").count }, 1 do
        result = create_invitation(email_address: "  Invitee@Example.Test ", organization_role: :member)
      end
    end

    assert_predicate result, :deliver?
    assert_equal "invitee@example.test", result.invitation.email_address
    assert_equal OrganizationInvitation.digest_token(result.raw_token), result.invitation.token_digest
    assert_not_equal result.raw_token, result.invitation.token_digest
    assert_in_delta 7.days.from_now, result.invitation.expires_at, 2.seconds

    duplicate = nil
    assert_no_difference -> { OrganizationInvitation.count } do
      assert_no_difference -> { AuditEvent.count } do
        duplicate = create_invitation(email_address: "INVITEE@example.test", organization_role: :admin)
      end
    end

    assert_equal result.invitation, duplicate.invitation
    assert_not_predicate duplicate, :deliver?
    assert_nil duplicate.raw_token
    assert_predicate duplicate.invitation, :member?
  end

  test "an active member cannot be invited" do
    member = create_test_user(email_address: "active-member@example.test")
    create_test_membership(organization: @organization, user: member, role: :member)

    assert_no_difference -> { OrganizationInvitation.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_invitation(email_address: member.email_address, organization_role: :admin)
      end
    end
  end

  test "invitation management enforces the exact organization role matrix" do
    admin = create_test_user(email_address: "invitation-admin@example.test")
    admin_membership = create_test_membership(
      organization: @organization,
      user: admin,
      role: :admin
    )
    establish_tenant_context(user: admin, organization: @organization, membership: admin_membership)

    assert_predicate create_invitation(
      email_address: "admin-target@example.test",
      organization_role: :admin
    ), :deliver?
    assert_predicate create_invitation(
      email_address: "member-target@example.test",
      organization_role: :member
    ), :deliver?

    %i[owner billing].each do |role|
      assert_raises(Pundit::NotAuthorizedError) do
        create_invitation(email_address: "#{role}-target@example.test", organization_role: role)
      end
    end

    %i[billing member].each do |role|
      actor = create_test_user(email_address: "#{role}-inviter@example.test")
      actor_membership = create_test_membership(
        organization: @organization,
        user: actor,
        role: role
      )
      establish_tenant_context(user: actor, organization: @organization, membership: actor_membership)

      assert_raises(Pundit::NotAuthorizedError) do
        create_invitation(
          email_address: "denied-#{role}@example.test",
          organization_role: :member
        )
      end
    end
  end

  test "resend rotates the token while revoke invalidates the invitation" do
    recipient = create_test_user(email_address: "resend-recipient@example.test")
    original = create_invitation(
      email_address: recipient.email_address,
      organization_role: :member
    )

    resent = Organizations::Invitations::Resend.new(
      actor: @owner,
      invitation_id: original.invitation.id
    ).call

    assert_predicate resent, :deliver?
    assert_not_equal original.raw_token, resent.raw_token
    assert_not_equal original.invitation.token_digest, resent.invitation.token_digest

    establish_invitation_context(recipient)
    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Invitations::Lookup.new(user: recipient, raw_token: original.raw_token).call
    end
    assert_equal resent.invitation,
      Organizations::Invitations::Lookup.new(user: recipient, raw_token: resent.raw_token).call

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    revoked = Organizations::Invitations::Revoke.new(
      actor: @owner,
      invitation_id: resent.invitation.id
    ).call

    assert_predicate revoked, :revoked?
    assert_not_nil revoked.revoked_at

    establish_invitation_context(recipient)
    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Invitations::Accept.new(user: recipient, raw_token: resent.raw_token).call
    end
  end

  test "accept creates one membership and locator and a used token is denied" do
    recipient = create_test_user(email_address: "accepted-recipient@example.test")
    delivery = create_invitation(
      email_address: recipient.email_address,
      organization_role: :admin
    )
    establish_invitation_context(recipient)

    membership = nil
    assert_difference -> { OrganizationMembership.count }, 1 do
      assert_difference -> { OrganizationAccessLocator.count }, 1 do
        membership = Organizations::Invitations::Accept.new(
          user: recipient,
          raw_token: delivery.raw_token
        ).call
      end
    end

    assert_predicate membership, :active?
    assert_predicate membership, :admin?
    assert_predicate delivery.invitation.reload, :accepted?
    assert_equal membership.id, recipient.organization_access_locators.sole.organization_membership_id

    assert_no_difference -> { OrganizationMembership.count } do
      assert_raises(ActiveRecord::RecordNotFound) do
        Organizations::Invitations::Accept.new(
          user: recipient,
          raw_token: delivery.raw_token
        ).call
      end
    end
  end

  test "accept reactivates a suspended membership with the invited role and preserves joined at" do
    recipient = create_test_user(email_address: "reactivated-recipient@example.test")
    joined_at = 3.months.ago
    suspended_membership = create_test_membership(
      organization: @organization,
      user: recipient,
      role: :member,
      status: :suspended,
      joined_at: joined_at
    )
    delivery = create_invitation(
      email_address: recipient.email_address,
      organization_role: :billing
    )
    establish_invitation_context(recipient)

    assert_no_difference -> { OrganizationMembership.count } do
      assert_difference -> { OrganizationAccessLocator.count }, 1 do
        Organizations::Invitations::Accept.new(
          user: recipient,
          raw_token: delivery.raw_token
        ).call
      end
    end

    suspended_membership.reload
    assert_predicate suspended_membership, :active?
    assert_predicate suspended_membership, :billing?
    assert_equal joined_at.change(usec: joined_at.usec), suspended_membership.joined_at
  end

  test "acceptance rolls back membership locator invitation and audit together" do
    recipient = create_test_user(email_address: "rollback-recipient@example.test")
    delivery = create_invitation(
      email_address: recipient.email_address,
      organization_role: :member
    )
    audit_count = AuditEvent.count
    establish_invitation_context(recipient)
    service = Organizations::Invitations::Accept.new(
      user: recipient,
      raw_token: delivery.raw_token
    )
    service.define_singleton_method(:record_audit_event!) do |**|
      raise "forced audit failure"
    end

    assert_no_difference [
      -> { OrganizationMembership.count },
      -> { OrganizationAccessLocator.count },
      -> { AuditEvent.count }
    ] do
      error = assert_raises(RuntimeError) { service.call }
      assert_match(/forced audit failure/, error.message)
    end

    assert_equal audit_count, AuditEvent.count
    assert_predicate delivery.invitation.reload, :pending?
  end

  test "acceptance consumes a stale invitation without changing an active membership role" do
    recipient = create_test_user(email_address: "already-joined-recipient@example.test")
    delivery = create_invitation(
      email_address: recipient.email_address,
      organization_role: :owner
    )
    membership = create_test_membership(
      organization: @organization,
      user: recipient,
      role: :member
    )
    establish_invitation_context(recipient)

    assert_no_difference -> { OrganizationMembership.count } do
      assert_difference -> { OrganizationAccessLocator.count }, 1 do
        Organizations::Invitations::Accept.new(
          user: recipient,
          raw_token: delivery.raw_token
        ).call
      end
    end

    assert_predicate membership.reload, :member?
    assert_predicate delivery.invitation.reload, :accepted?
  end

  test "wrong email and expired tokens fail closed without creating membership" do
    recipient = create_test_user(email_address: "expiry-recipient@example.test")
    wrong_user = create_test_user(email_address: "wrong-invitation-user@example.test")
    delivery = create_invitation(
      email_address: recipient.email_address,
      organization_role: :member
    )

    establish_invitation_context(wrong_user)
    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Invitations::Accept.new(user: wrong_user, raw_token: delivery.raw_token).call
    end
    assert_predicate delivery.invitation.reload, :pending?

    travel 8.days
    establish_invitation_context(recipient)
    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Invitations::Accept.new(user: recipient, raw_token: delivery.raw_token).call
    end

    assert_predicate delivery.invitation.reload, :expired?
    assert_not @organization.organization_memberships.exists?(user_id: recipient.id)
  end

  test "invitation identifiers are always resolved through the current organization" do
    foreign_owner = create_test_user(email_address: "foreign-invitation-owner@example.test")
    foreign_organization, foreign_owner_membership = create_test_organization_with_owner(
      owner: foreign_owner,
      name: "Foreign Invitation Organization",
      slug: "foreign-invitation-organization"
    )
    establish_tenant_context(
      user: foreign_owner,
      organization: foreign_organization,
      membership: foreign_owner_membership
    )
    foreign_invitation = create_invitation(
      email_address: "foreign-recipient@example.test",
      organization_role: :member
    ).invitation

    establish_tenant_context(
      user: @owner,
      organization: @organization,
      membership: @owner_membership
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      Organizations::Invitations::Revoke.new(
        actor: @owner,
        invitation_id: foreign_invitation.id
      ).call
    end
    assert_predicate foreign_invitation.reload, :pending?
  end

  private
    def create_invitation(email_address:, organization_role:)
      Organizations::Invitations::Create.new(
        actor: Current.user,
        email_address: email_address,
        organization_role: organization_role
      ).call
    end

    def establish_invitation_context(user)
      Current.reset
      session_record, = Session.issue_for!(user, ip_address: nil, user_agent: "Invitation test")
      Current.session = session_record
      Current.organization = @organization
      Current.membership = nil
    end
end
