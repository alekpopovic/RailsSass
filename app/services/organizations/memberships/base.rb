class Organizations::Memberships::Base
  private
    def initialize_context(actor:, membership_id:)
      @actor = actor
      @membership_id = membership_id
    end

    def with_locked_memberships
      organization = Current.organization
      raise_not_authorized! unless organization && @actor&.persisted?

      Organization.transaction do
        organization.lock!
        raise_not_authorized! unless organization.active? && Current.organization&.id == organization.id

        scope = Current.organization.organization_memberships
        locked_memberships = scope
          .where(id: @membership_id)
          .or(scope.where(user_id: @actor.id))
          .order(:id)
          .lock
          .to_a

        actor_membership = locked_memberships.find { |membership| membership.user_id == @actor.id }
        target_membership = locked_memberships.find { |membership| membership.id == @membership_id.to_i }

        raise ActiveRecord::RecordNotFound, "organization membership not found" unless target_membership
        authorize_current_actor!(actor_membership)

        yield scope, actor_membership, target_membership
      end
    end

    def authorize_current_actor!(actor_membership)
      actor_user = User.lock.find_by(id: actor_membership&.user_id)
      authorized = Current.user&.id == @actor.id &&
        Current.membership&.id == actor_membership&.id &&
        actor_membership&.active? &&
        actor_user&.authentication_allowed? &&
        AuthorizationContext.current.authenticated?

      raise_not_authorized! unless authorized
    end

    def authorize_membership_management!(
      actor_membership,
      target_membership,
      new_role: nil,
      allowed_statuses: %w[active]
    )
      allowed = if !target_membership.status.in?(allowed_statuses)
        false
      elsif actor_membership.owner?
        true
      elsif actor_membership.admin?
        manageable_roles = %w[admin member]
        manageable_roles.include?(target_membership.role) &&
          (new_role.nil? || manageable_roles.include?(new_role))
      else
        false
      end

      raise_not_authorized! unless allowed
    end

    def ensure_access_locator!(membership)
      Current.organization.organization_access_locators.find_or_create_by!(
        organization_membership_id: membership.id
      ) do |locator|
        locator.user = membership.user
        locator.organization = Current.organization
      end
    end

    def record_audit_event!(action:, subject:, metadata: {})
      AuditEvents::Record.call(
        organization: Current.organization,
        actor_user: @actor,
        action: action,
        subject: subject,
        metadata: metadata
      )
    end

    def ensure_another_active_owner!(scope, target_membership)
      return unless target_membership.owner? && target_membership.active?
      return if scope.active_owners.where.not(id: target_membership.id).exists?

      target_membership.errors.add(:base, OrganizationMembership::LAST_ACTIVE_OWNER_MESSAGE)
      raise ActiveRecord::RecordInvalid, target_membership
    end

    def persist_transition!(scope, target_membership, attributes)
      affected_rows = scope.where(id: target_membership.id).update_all(
        attributes.merge(updated_at: Time.current)
      )
      raise ActiveRecord::RecordNotFound, "organization membership not found" unless affected_rows == 1

      updated_membership = scope.find(target_membership.id)
      if Current.membership&.id == updated_membership.id
        Current.membership = updated_membership
      end
      updated_membership
    end

    def raise_not_authorized!
      raise Pundit::NotAuthorizedError, "organization membership management is not allowed"
    end
end
