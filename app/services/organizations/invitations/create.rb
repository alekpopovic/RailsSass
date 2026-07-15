class Organizations::Invitations::Create < Organizations::Invitations::Base
  Result = Data.define(:invitation, :raw_token, :deliver) do
    def deliver?
      deliver
    end
  end

  def initialize(actor:, email_address:, organization_role:)
    initialize_actor(actor)
    @email_address = User.normalize_email(email_address)
    @organization_role = organization_role.to_s
  end

  def call
    with_locked_organization_actor do |actor_membership|
      now = Time.current
      target_membership = membership_for_email(@email_address)
      authorize_role_management!(
        actor_membership,
        @organization_role,
        target_membership: target_membership
      )

      pending_invitation = Current.organization.organization_invitations
        .pending
        .where(email_address: @email_address)
        .lock
        .first

      if pending_invitation&.expired_for?(now: now)
        expire_invitation!(pending_invitation, now: now)
        pending_invitation = nil
      end

      candidate = Current.organization.organization_invitations.build(
        inviter: @actor,
        email_address: @email_address,
        organization_role: @organization_role,
        status: :pending,
        token_digest: OrganizationInvitation.digest_token("validation-placeholder"),
        expires_at: now + TOKEN_LIFETIME
      )
      invalid_record!(candidate, "is already an active organization member") if target_membership&.active?
      candidate.valid?
      candidate.errors.delete(:email_address, :taken) if pending_invitation
      invalid_record!(candidate, "is invalid") if candidate.errors.any?

      if pending_invitation
        authorize_role_management!(
          actor_membership,
          pending_invitation.organization_role,
          target_membership: target_membership
        )
        next Result.new(invitation: pending_invitation, raw_token: nil, deliver: false)
      end

      raw_token, token_digest = generate_token_pair
      invitation = Current.organization.organization_invitations.create!(
        inviter: @actor,
        email_address: @email_address,
        organization_role: @organization_role,
        status: :pending,
        token_digest: token_digest,
        expires_at: now + TOKEN_LIFETIME
      )
      record_audit_event!(
        actor_user: @actor,
        action: "organization.invitation.created",
        subject: invitation,
        metadata: { organization_role: invitation.organization_role }
      )

      Result.new(invitation: invitation, raw_token: raw_token, deliver: true)
    end
  end
end
