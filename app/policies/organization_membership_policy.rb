class OrganizationMembershipPolicy < ApplicationPolicy
  def change_role?
    active_record? && manageable_role? && record.active?
  end

  alias_method :suspend?, :change_role?

  def reactivate?
    active_record? && manageable_role? && record.suspended?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless authorized_context?

      scope.where(organization_id: organization.id)
    end

    private
      def authorized_context?
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
    def active_record?
      user&.authentication_allowed? &&
        organization&.persisted? &&
        organization.active? &&
        membership&.persisted? &&
        membership.active? &&
        membership.organization_id == organization.id &&
        membership.user_id == user.id &&
        record&.persisted? &&
        record.organization_id == organization.id
    end

    def manageable_role?
      membership.owner? || (membership.admin? && record.role.in?(%w[admin member]))
    end
end
