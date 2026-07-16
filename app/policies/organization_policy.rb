class OrganizationPolicy < ApplicationPolicy
  def show?
    active_context?
  end

  alias_method :dashboard?, :show?

  def members?
    active_context? && membership.role.in?(%w[owner admin])
  end

  def settings?
    active_context? && membership.role.in?(%w[owner admin])
  end

  alias_method :update?, :settings?

  def products?
    active_context?
  end

  alias_method :pricing?, :products?

  def billing?
    active_context? && membership.role.in?(%w[owner billing])
  end

  private
    def active_context?
      user&.authentication_allowed? &&
        record&.persisted? &&
        record.active? &&
        organization&.id == record.id &&
        membership&.persisted? &&
        membership.active? &&
        membership.organization_id == record.id &&
        membership.user_id == user.id
    end
end
