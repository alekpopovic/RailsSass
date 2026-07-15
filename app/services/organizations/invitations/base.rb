require "securerandom"

class Organizations::Invitations::Base
  TOKEN_BYTE_LENGTH = 32
  TOKEN_LIFETIME = 7.days

  private
    def initialize_actor(actor)
      @actor = actor
    end

    def with_locked_organization_actor
      organization = Current.organization
      raise_not_authorized! unless organization&.persisted? && @actor&.persisted?

      Organization.transaction do
        organization.lock!
        raise_not_authorized! unless organization.active? && Current.organization&.id == organization.id

        actor_membership = Current.organization.organization_memberships
          .where(user_id: @actor.id)
          .lock
          .first
        actor_user = User.lock.find_by(id: @actor.id)
        authorized = Current.user&.id == @actor.id &&
          Current.membership&.id == actor_membership&.id &&
          actor_membership&.active? &&
          actor_user&.authentication_allowed?
        raise_not_authorized! unless authorized

        yield actor_membership
      end
    end

    def authorize_role_management!(actor_membership, organization_role, target_membership: nil)
      allowed = if actor_membership.owner?
        true
      elsif actor_membership.admin?
        manageable_roles = %w[admin member]
        manageable_roles.include?(organization_role.to_s) &&
          (target_membership.nil? || manageable_roles.include?(target_membership.role))
      else
        false
      end

      raise_not_authorized! unless allowed
    end

    def membership_for_email(email_address)
      Current.organization.organization_memberships
        .joins(:user)
        .where(users: { email_address: email_address })
        .lock
        .first
    end

    def update_invitation!(invitation, attributes, now: Time.current)
      affected_rows = Current.organization.organization_invitations
        .where(id: invitation.id)
        .update_all(attributes.merge(updated_at: now))
      raise ActiveRecord::RecordNotFound, "organization invitation not found" unless affected_rows == 1

      Current.organization.organization_invitations.find(invitation.id)
    end

    def expire_invitation!(invitation, actor_user: @actor, now: Time.current)
      expired_invitation = update_invitation!(invitation, { status: "expired" }, now: now)
      record_audit_event!(
        actor_user: actor_user,
        action: "organization.invitation.expired",
        subject: expired_invitation
      )
      expired_invitation
    end

    def generate_token_pair
      raw_token = SecureRandom.urlsafe_base64(TOKEN_BYTE_LENGTH)
      [ raw_token, OrganizationInvitation.digest_token(raw_token) ]
    end

    def invalid_record!(record, message)
      record.errors.add(:base, message)
      raise ActiveRecord::RecordInvalid, record
    end

    def record_audit_event!(actor_user:, action:, subject:, metadata: {})
      AuditEvents::Record.call(
        organization: Current.organization,
        actor_user: actor_user,
        action: action,
        subject: subject,
        metadata: metadata
      )
    end

    def raise_not_authorized!
      raise Pundit::NotAuthorizedError, "organization invitation management is not allowed"
    end
end
