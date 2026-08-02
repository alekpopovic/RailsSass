class OrganizationMembershipPolicy < ApplicationPolicy
  module ManagementContext
    private
      def active_membership_context?
        authenticated_context? &&
          Current.user&.id == user&.id &&
          organization&.persisted? &&
          organization.active? &&
          Current.organization&.id == organization.id &&
          Organization.where(id: organization.id, status: "active").exists? &&
          membership&.persisted? &&
          membership.active? &&
          Current.membership&.id == membership.id &&
          membership.organization_id == organization.id &&
          membership.user_id == user.id &&
          authoritative_membership_role.present?
      end

      def authoritative_membership_role
        return unless organization&.persisted? && membership&.persisted? && user&.persisted?

        organization.organization_memberships.active.where(
          id: membership.id,
          user_id: user.id
        ).pick(:role)
      end
  end

  include ManagementContext

  def change_role?
    active_record? && manageable_role? && record.active?
  end

  alias_method :suspend?, :change_role?

  def reactivate?
    active_record? && manageable_role? && record.suspended?
  end

  class Scope < ApplicationPolicy::Scope
    include ManagementContext

    def resolve
      return scope.none unless authorized_context?

      scope.where(organization_id: organization.id)
    end

    private
      def authorized_context?
        active_membership_context? && authoritative_membership_role.in?(%w[owner admin])
      end
  end

  private
    def active_record?
      active_membership_context? &&
        record&.persisted? &&
        record.organization_id == organization.id
    end

    def manageable_role?
      actor_role = authoritative_membership_role
      actor_role == "owner" || (actor_role == "admin" && record.role.in?(%w[admin member]))
    end
end
