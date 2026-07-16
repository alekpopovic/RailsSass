class Organizations::UpdateSettings
  def initialize(actor:, name:)
    @actor = actor
    @name = name
  end

  def call
    organization = Current.organization
    raise_not_authorized! unless organization&.persisted? && @actor&.persisted?

    Organization.transaction do
      organization.lock!
      actor = User.lock.find_by(id: @actor.id)
      membership = organization.organization_memberships.active.lock.find_by(
        id: Current.membership&.id,
        user_id: @actor.id,
        role: %w[owner admin]
      )
      authorize_current_context!(organization, actor, membership)

      previous_name = organization.name
      organization.update!(name: @name)
      record_audit_event!(organization) if organization.name != previous_name
      organization
    end
  end

  private
    def authorize_current_context!(organization, actor, membership)
      authorized = organization.active? &&
        Current.organization&.id == organization.id &&
        Current.user&.id == actor&.id &&
        Current.membership&.id == membership&.id &&
        actor&.authentication_allowed? &&
        AuthorizationContext.current.authenticated?

      raise_not_authorized! unless authorized
    end

    def record_audit_event!(organization)
      AuditEvents::Record.call(
        organization: organization,
        actor_user: @actor,
        action: "organization.settings.updated",
        subject: organization
      )
    end

    def raise_not_authorized!
      raise Pundit::NotAuthorizedError, "organization settings update is not allowed"
    end
end
