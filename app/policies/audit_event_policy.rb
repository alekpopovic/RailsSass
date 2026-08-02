class AuditEventPolicy < ApplicationPolicy
  module ViewingContext
    private
      def audit_viewing_context?
        current_organization = Current.organization
        current_membership = Current.membership

        return false unless authenticated_context?
        return false unless Current.user&.id == user&.id
        return false unless organization&.persisted? && current_organization&.id == organization.id
        return false unless membership&.persisted? && current_membership&.id == membership.id
        return false unless current_organization.active?
        return false unless Organization.where(id: current_organization.id, status: "active").exists?

        current_organization.organization_memberships.active.exists?(
          id: membership.id,
          user_id: user.id,
          role: %w[owner admin]
        )
      end
  end

  include ViewingContext

  def index?
    record == AuditEvent && audit_viewing_context?
  end

  class Scope < ApplicationPolicy::Scope
    include ViewingContext

    def resolve
      tenant_scope = current_organization_scope
      return tenant_scope.none unless audit_viewing_context?

      tenant_scope.merge(scope)
    end

    private
      def current_organization_scope
        return scope.none unless Current.organization&.persisted?

        Current.organization.audit_events
      end
  end
end
