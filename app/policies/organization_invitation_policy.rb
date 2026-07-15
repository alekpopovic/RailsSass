class OrganizationInvitationPolicy < ApplicationPolicy
  def index?
    management_context?
  end

  def create?
    management_context? && manageable_role?(record.organization_role)
  end

  def new?
    management_context?
  end

  def resend?
    create? && record.pending?
  end

  def revoke?
    create? && (record.pending? || record.revoked?)
  end

  def accept?
    user&.authentication_allowed? &&
      organization&.persisted? &&
      organization.active? &&
      record&.persisted? &&
      record.organization_id == organization.id &&
      record.pending? &&
      !record.expired_for? &&
      record.email_address == User.normalize_email(user.email_address)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless management_context?

      tenant_scope = scope.where(organization_id: organization.id)
      membership.owner? ? tenant_scope : tenant_scope.where(organization_role: %w[admin member])
    end

    private
      def management_context?
        user&.authentication_allowed? &&
          organization&.persisted? &&
          organization.active? &&
          membership&.persisted? &&
          membership.active? &&
          membership.organization_id == organization.id &&
          membership.user_id == user.id &&
          membership.role.in?(%w[owner admin])
      end
  end

  private
    def management_context?
      user&.authentication_allowed? &&
        organization&.persisted? &&
        organization.active? &&
        membership&.persisted? &&
        membership.active? &&
        membership.organization_id == organization.id &&
        membership.user_id == user.id &&
        membership.role.in?(%w[owner admin]) &&
        record&.organization_id == organization.id
    end

    def manageable_role?(organization_role)
      membership.owner? || (membership.admin? && organization_role.to_s.in?(%w[admin member]))
    end
end
