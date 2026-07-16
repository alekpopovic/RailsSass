class Access::ProductMemberships::Base
  private
    def initialize_actor(actor)
      @actor = actor
    end

    def with_locked_organization
      organization = Current.organization
      raise ActiveRecord::RecordNotFound, "organization not found" unless active_current_organization?(organization)

      Organization.transaction do
        organization.lock!
        raise ActiveRecord::RecordNotFound, "organization not found" unless active_current_organization?(organization)

        yield organization
      end
    end

    def authorize_actor_for_product!(organization, product_id)
      return unless @actor

      actor_membership = organization.organization_memberships
        .where(user_id: @actor.id)
        .lock
        .first
      actor_user = User.lock.find_by(id: @actor.id)
      authorized = @actor.persisted? &&
        Current.user&.id == @actor.id &&
        Current.membership&.id == actor_membership&.id &&
        actor_membership&.active? &&
        actor_membership&.role.in?(%w[owner admin]) &&
        actor_user&.authentication_allowed? &&
        AuthorizationContext.current.authenticated?
      raise_not_authorized! unless authorized

      product_key = Product.where(id: product_id).pick(:key)
      entitled = product_key && Entitlements::Resolver.new(
        organization: organization
      ).product_enabled?(product_key)
      raise_not_authorized! unless entitled
    end

    def locked_product_membership!(organization, product_membership_id)
      organization.product_memberships.lock.find(product_membership_id)
    end

    def locked_active_organization_membership!(organization, organization_membership_id)
      membership = organization.organization_memberships.lock.find(organization_membership_id)
      invalid_record!(membership, "organization membership must be active") unless membership.active?
      membership
    end

    def locked_active_product!(product_id)
      Product.where(active: true).lock.find(product_id)
    end

    def transition!(organization, product_membership, status:)
      affected_rows = organization.product_memberships
        .where(id: product_membership.id)
        .update_all(status: status, updated_at: Time.current)
      raise ActiveRecord::RecordNotFound, "product membership not found" unless affected_rows == 1

      organization.product_memberships.find(product_membership.id)
    end

    def enforce_seat_limit!(organization, product, product_membership)
      Entitlements::LimitEnforcer.new(
        organization: organization,
        product_key: product.key,
        feature_key: Entitlements::Usage::SEAT_FEATURE_KEY
      ).enforce!(delta: 1)
    rescue Entitlements::LimitExceeded => error
      invalid_record!(product_membership, error.safe_message)
    end

    def record_audit_event!(action:, subject:, metadata: {})
      return unless @actor

      AuditEvents::Record.call(
        organization: Current.organization,
        actor_user: @actor,
        action: action,
        subject: subject,
        metadata: metadata
      )
    end

    def audit_metadata(product_membership, product_role: nil)
      metadata = {
        membership_id: product_membership.organization_membership_id,
        product_key: Product.where(id: product_membership.product_id).pick(:key)
      }
      metadata[:product_role_key] = product_role.key if product_role
      metadata
    end

    def invalid_record!(record, message)
      record.errors.add(:base, message)
      raise ActiveRecord::RecordInvalid, record
    end

    def active_current_organization?(organization)
      organization&.persisted? && organization.active? && Current.organization&.id == organization.id
    end

    def raise_not_authorized!
      raise Pundit::NotAuthorizedError, "product membership management is not allowed"
    end
end
