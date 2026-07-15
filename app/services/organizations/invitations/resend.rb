class Organizations::Invitations::Resend < Organizations::Invitations::Base
  Result = Data.define(:invitation, :raw_token, :deliver) do
    def deliver?
      deliver
    end
  end

  def initialize(actor:, invitation_id:)
    initialize_actor(actor)
    @invitation_id = invitation_id
  end

  def call
    result = with_locked_organization_actor do |actor_membership|
      now = Time.current
      invitation = Current.organization.organization_invitations.lock.find(@invitation_id)
      target_membership = membership_for_email(invitation.email_address)
      authorize_role_management!(
        actor_membership,
        invitation.organization_role,
        target_membership: target_membership
      )
      invalid_record!(invitation, "recipient is already an active organization member") if target_membership&.active?

      if invitation.pending? && invitation.expired_for?(now: now)
        next Result.new(
          invitation: expire_invitation!(invitation, now: now),
          raw_token: nil,
          deliver: false
        )
      end
      invalid_record!(invitation, "cannot be resent") unless invitation.pending?

      raw_token, token_digest = generate_token_pair
      invitation = update_invitation!(
        invitation,
        { token_digest: token_digest, expires_at: now + TOKEN_LIFETIME },
        now: now
      )
      record_audit_event!(
        actor_user: @actor,
        action: "organization.invitation.resent",
        subject: invitation
      )

      Result.new(invitation: invitation, raw_token: raw_token, deliver: true)
    end

    invalid_record!(result.invitation, "has expired") unless result.deliver?
    result
  end
end
