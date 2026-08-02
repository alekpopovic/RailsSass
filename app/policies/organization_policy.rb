class OrganizationPolicy < ApplicationPolicy
  def create?
    authenticated_context? && Current.user&.id == user&.id
  end

  alias_method :new?, :create?

  def show?
    active_context?
  end

  alias_method :dashboard?, :show?

  def members?
    active_context? && authoritative_membership_role.in?(%w[owner admin])
  end

  def settings?
    active_context? && authoritative_membership_role.in?(%w[owner admin])
  end

  alias_method :update?, :settings?

  def products?
    active_context?
  end

  alias_method :pricing?, :products?

  def billing?
    active_context? && authoritative_membership_role.in?(%w[owner billing])
  end

  alias_method :checkout?, :billing?
  alias_method :portal?, :billing?
  alias_method :change_plan?, :billing?

  private
    def active_context?
      authenticated_context? &&
        Current.user&.id == user&.id &&
        record&.persisted? &&
        record.active? &&
        organization&.id == record.id &&
        Current.organization&.id == organization.id &&
        Organization.where(id: organization.id, status: "active").exists? &&
        membership&.persisted? &&
        membership.active? &&
        Current.membership&.id == membership.id &&
        membership.organization_id == record.id &&
        membership.user_id == user.id &&
        organization.organization_memberships.active.exists?(
          id: membership.id,
          user_id: user.id
        )
    end

    def authoritative_membership_role
      organization.organization_memberships.active.where(
        id: membership.id,
        user_id: user.id
      ).pick(:role)
    end
end
