class Organizations::Invitations::Revoke < Organizations::Invitations::Base
  def initialize(actor:, invitation_id:)
    initialize_actor(actor)
    @invitation_id = invitation_id
  end

  def call
    with_locked_organization_actor do |actor_membership|
      now = Time.current
      invitation = Current.organization.organization_invitations.lock.find(@invitation_id)
      target_membership = membership_for_email(invitation.email_address)
      authorize_role_management!(
        actor_membership,
        invitation.organization_role,
        target_membership: target_membership
      )

      if invitation.pending? && invitation.expired_for?(now: now)
        expire_invitation!(invitation, now: now)
      elsif invitation.pending?
        revoked_invitation = update_invitation!(
          invitation,
          { status: "revoked", revoked_at: now },
          now: now
        )
        record_audit_event!(
          actor_user: @actor,
          action: "organization.invitation.revoked",
          subject: revoked_invitation
        )
        revoked_invitation
      elsif invitation.revoked?
        invitation
      else
        invalid_record!(invitation, "cannot be revoked")
      end
    end
  end
end
