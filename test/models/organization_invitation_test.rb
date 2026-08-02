require "test_helper"
require_relative "../support/organization_test_helper"

class OrganizationInvitationTest < ActiveSupport::TestCase
  include OrganizationTestHelper

  setup do
    @owner = create_test_user(email_address: "invitation-owner@example.test")
    @organization, @owner_membership = create_test_organization_with_owner(owner: @owner)
  end

  test "normalizes email and exposes role and lifecycle enums" do
    invitation = create_invitation(email_address: "  INVITED@Example.Test ", organization_role: :admin)

    assert_equal "invited@example.test", invitation.email_address
    assert_predicate invitation, :admin?
    assert_predicate invitation, :pending?
    assert_equal @organization, invitation.organization
    assert_equal @owner, invitation.inviter
  end

  test "digests a nonblank raw token without retaining it" do
    raw_token = SecureRandom.urlsafe_base64(32)

    assert_equal Digest::SHA256.hexdigest(raw_token), OrganizationInvitation.digest_token(raw_token)
    assert_nil OrganizationInvitation.digest_token("")
    assert_nil OrganizationInvitation.digest_token("x" * (OrganizationInvitation::RAW_TOKEN_MAX_BYTES + 1))
    assert_not_includes OrganizationInvitation.column_names, "token"
  end

  test "active scope and expiry predicate use an explicit time boundary" do
    now = Time.current
    active = create_invitation(email_address: "active@example.test", expires_at: 1.hour.from_now(now))
    elapsed = create_invitation(
      email_address: "elapsed@example.test",
      created_at: 2.hours.ago(now),
      expires_at: 1.second.ago(now)
    )

    assert_includes @organization.organization_invitations.active_at(now), active
    assert_not_includes @organization.organization_invitations.active_at(now), elapsed
    assert_not active.expired_for?(now: now)
    assert elapsed.expired_for?(now: now)
  end

  test "database permits only one pending invitation for normalized email in an organization" do
    create_invitation(email_address: "duplicate@example.test")

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      OrganizationInvitation.insert_all!([ raw_attributes(
        email_address: "duplicate@example.test",
        token_digest: token_digest
      ) ])
    end

    assert_kind_of PG::UniqueViolation, error.cause
  end

  test "accepted and revoked history no longer blocks a new pending invitation" do
    now = Time.current
    create_invitation(
      email_address: "accepted@example.test",
      status: :accepted,
      created_at: now,
      accepted_at: now,
      expires_at: 1.day.from_now(now)
    )

    assert_difference -> { @organization.organization_invitations.count }, 1 do
      create_invitation(email_address: "accepted@example.test")
    end
  end

  test "database composite foreign key requires the inviter to belong to the organization" do
    other_owner = create_test_user(email_address: "other-inviter@example.test")
    create_test_organization_with_owner(
      owner: other_owner,
      name: "Other Invitation Organization",
      slug: "other-invitation-organization"
    )

    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      OrganizationInvitation.insert_all!([ raw_attributes(inviter_id: other_owner.id) ])
    end

    assert_kind_of PG::ForeignKeyViolation, error.cause
  end

  test "database enforces token digest uniqueness and shape" do
    invitation = create_invitation

    duplicate_error = assert_raises(ActiveRecord::RecordNotUnique) do
      OrganizationInvitation.insert_all!([ raw_attributes(
        email_address: "other@example.test",
        token_digest: invitation.token_digest
      ) ])
    end
    assert_kind_of PG::UniqueViolation, duplicate_error.cause
  end

  test "database enforces lifecycle timestamp consistency" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      OrganizationInvitation.insert_all!([ raw_attributes(
        status: "accepted",
        accepted_at: nil
      ) ])
    end

    assert_kind_of PG::CheckViolation, error.cause
  end

  test "invitation identity and requested role are immutable" do
    invitation = create_invitation

    %i[organization_id inviter_id email_address organization_role].each do |attribute|
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        invitation.update!(attribute => replacement_for(attribute))
      end
    end
  end

  test "membership exposes invitations created by its user in the same tenant" do
    invitation = create_invitation

    assert_includes @owner_membership.organization_invitations_as_inviter, invitation
    assert_includes @owner.sent_organization_invitations, invitation
  end

  private
    def create_invitation(**overrides)
      attributes = {
        inviter: @owner,
        email_address: "invitee-#{SecureRandom.hex(4)}@example.test",
        organization_role: :member,
        status: :pending,
        token_digest: token_digest,
        expires_at: 7.days.from_now
      }.merge(overrides)

      @organization.organization_invitations.create!(attributes)
    end

    def raw_attributes(**overrides)
      now = Time.current
      {
        organization_id: @organization.id,
        inviter_id: @owner.id,
        email_address: "raw-#{SecureRandom.hex(4)}@example.test",
        organization_role: "member",
        status: "pending",
        token_digest: token_digest,
        expires_at: 7.days.from_now(now),
        accepted_at: nil,
        revoked_at: nil,
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def token_digest
      OrganizationInvitation.digest_token(SecureRandom.urlsafe_base64(32))
    end

    def replacement_for(attribute)
      {
        organization_id: -1,
        inviter_id: -1,
        email_address: "changed@example.test",
        organization_role: "admin"
      }.fetch(attribute)
    end
end
