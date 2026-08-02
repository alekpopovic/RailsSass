class Organizations::Create
  def initialize(user:, name:, slug:)
    @user = user
    @name = name
    @slug = slug
  end

  def call
    authorize_identity!

    organization = Organization.new(name: @name, slug: @slug)
    membership = nil

    Organization.transaction do
      user = User.lock.find_by(id: @user.id)
      authorize_user!(user)
      organization.save!
      membership = organization.organization_memberships.create!(
        user: user,
        role: :owner,
        status: :active,
        joined_at: Time.current
      )
      membership.create_organization_access_locator!(
        user: user,
        organization: organization
      )
      AuditEvents::Record.call(
        organization: organization,
        actor_user: user,
        action: "organization.created",
        subject: organization
      )
      AuditEvents::Record.call(
        organization: organization,
        actor_user: user,
        action: "organization.membership.created",
        subject: membership,
        metadata: { organization_role: membership.role }
      )
    end

    ActiveRecord.after_all_transactions_commit do
      Current.organization = organization
      Current.membership = membership
    end

    organization
  end

  private
    def authorize_identity!
      authorized = @user&.persisted? && Current.user&.id == @user.id

      raise Pundit::NotAuthorizedError, "verified authentication is required" unless authorized
    end

    def authorize_user!(user)
      authorized = user&.authentication_allowed? &&
        AuthorizationContext.current.authenticated?

      raise Pundit::NotAuthorizedError, "verified authentication is required" unless authorized
    end
end
