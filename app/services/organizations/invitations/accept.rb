class Organizations::Invitations::Accept < Organizations::Invitations::Base
  def initialize(user:, raw_token:)
    @user = user
    @raw_token = raw_token.to_s
  end

  def call
    organization = Current.organization
    raise ActiveRecord::RecordNotFound unless organization&.persisted? && @raw_token.present?

    result = Organization.transaction do
      organization.lock!
      now = Time.current
      user = User.lock.find_by(id: @user&.id)
      authorized_identity = organization.active? &&
        Current.organization&.id == organization.id &&
        Current.user&.id == user&.id &&
        user&.authentication_allowed?
      next :invalid unless authorized_identity

      invitation = Current.organization.organization_invitations
        .lock
        .find_by(token_digest: OrganizationInvitation.digest_token(@raw_token))
      next :invalid unless invitation

      if invitation.pending? && invitation.expired_for?(now: now)
        expire_invitation!(invitation, actor_user: nil, now: now)
        next :invalid
      end
      next :invalid unless invitation.pending?
      next :invalid unless invitation.email_address == User.normalize_email(user.email_address)

      membership = Current.organization.organization_memberships
        .where(user_id: user.id)
        .lock
        .first
      membership_transition = nil

      if membership&.suspended?
        Current.organization.organization_memberships.where(id: membership.id).update_all(
          role: invitation.organization_role,
          status: "active",
          updated_at: now
        )
        membership = Current.organization.organization_memberships.find(membership.id)
        membership_transition = "reactivated"
      elsif membership.nil?
        membership = Current.organization.organization_memberships.create!(
          user: user,
          role: invitation.organization_role,
          status: :active,
          joined_at: now
        )
        membership_transition = "created"
      end

      Current.organization.organization_access_locators.find_or_create_by!(
        organization_membership_id: membership.id
      ) do |locator|
        locator.user = user
        locator.organization = Current.organization
      end

      invitation = update_invitation!(
        invitation,
        { status: "accepted", accepted_at: now },
        now: now
      )
      record_audit_event!(
        actor_user: user,
        action: "organization.invitation.accepted",
        subject: invitation,
        metadata: { membership_id: membership.id }
      )
      if membership_transition
        record_audit_event!(
          actor_user: user,
          action: "organization.membership.#{membership_transition}",
          subject: membership,
          metadata: { source: "organization_invitation" }
        )
      end

      ActiveRecord.after_all_transactions_commit do
        Current.membership = membership if Current.organization&.id == organization.id
      end
      membership
    end

    raise ActiveRecord::RecordNotFound if result == :invalid

    result
  end
end
