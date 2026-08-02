class OrganizationInvitationPolicy < ApplicationPolicy
  module InvitationContext
    private
      def authenticated_organization_context?
        authenticated_context? &&
          Current.user&.id == user&.id &&
          organization&.persisted? &&
          organization.active? &&
          Current.organization&.id == organization.id &&
          Organization.where(id: organization.id, status: "active").exists?
      end

      def management_context?
        authenticated_organization_context? &&
          membership&.persisted? &&
          membership.active? &&
          Current.membership&.id == membership.id &&
          membership.organization_id == organization.id &&
          membership.user_id == user.id &&
          authoritative_membership_role.in?(%w[owner admin])
      end

      def authoritative_membership_role
        return unless organization&.persisted? && membership&.persisted? && user&.persisted?

        organization.organization_memberships.active.where(
          id: membership.id,
          user_id: user.id
        ).pick(:role)
      end
  end

  include InvitationContext

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
    authenticated_organization_context? &&
      record&.persisted? &&
      record.organization_id == organization.id &&
      record.pending? &&
      !record.expired_for? &&
      record.email_address == User.normalize_email(user.email_address)
  end

  class Scope < ApplicationPolicy::Scope
    include InvitationContext

    def resolve
      return scope.none unless management_context?

      tenant_scope = scope.where(organization_id: organization.id)
      return tenant_scope if authoritative_membership_role == "owner"

      tenant_scope.where(organization_role: %w[admin member])
    end
  end

  private
    def management_context?
      super &&
        record&.organization_id == organization.id
    end

    def manageable_role?(organization_role)
      actor_role = authoritative_membership_role
      actor_role == "owner" || (actor_role == "admin" && organization_role.to_s.in?(%w[admin member]))
    end
end
