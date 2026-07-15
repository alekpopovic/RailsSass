class OrganizationMembershipPolicy < ApplicationPolicy
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
end
