class ProductMembershipPolicy < ApplicationPolicy
  module ManagementContext
    private
      def product_membership_management_context?
        current_user = Current.user
        current_organization = Current.organization
        current_membership = Current.membership

        return false unless context.respond_to?(:authenticated?) && context.authenticated?
        return false unless current_user&.id == user.id
        return false unless organization&.persisted? && organization.active?
        return false unless current_organization&.id == organization.id && current_organization.active?
        return false unless Organization.where(id: current_organization.id, status: "active").exists?
        return false unless membership&.persisted? && current_membership&.id == membership.id

        current_organization.organization_memberships.active.exists?(
          id: membership.id,
          user_id: user.id,
          role: %w[owner admin]
        )
      end

      def product_entitled?(product_id)
        product_key = Product.where(id: product_id).pick(:key)
        return false unless product_key

        Entitlements::Resolver.new(
          organization: Current.organization
        ).product_enabled?(product_key)
      end
  end

  include ManagementContext

  def index?
    product_membership_management_context? && Entitlements::Resolver.new(
      organization: Current.organization
    ).enabled_products.any?
  end

  def show?
    manageable_record? && record.persisted?
  end

  def create?
    manageable_record? &&
      record.new_record? &&
      active_target_membership? &&
      active_product?
  end

  def update?
    manageable_record? && record.persisted?
  end

  def assign_role?
    update? && record.active? && active_product?
  end

  def suspend?
    update? && record.active?
  end

  def reactivate?
    update? && record.suspended? && active_target_membership? && active_product?
  end

  def destroy?
    update?
  end

  class Scope < ApplicationPolicy::Scope
    include ManagementContext

    def resolve
      tenant_scope = current_organization_scope
      return tenant_scope.none unless product_membership_management_context?

      enabled_product_keys = Entitlements::Resolver.new(
        organization: Current.organization
      ).enabled_products
      return tenant_scope.none if enabled_product_keys.empty?

      tenant_scope.where(
        product_id: Product.where(key: enabled_product_keys).select(:id)
      )
    end

    private
      def current_organization_scope
        current_organization = Current.organization
        return scope.none unless current_organization&.persisted?

        current_organization.product_memberships.merge(scope)
      end
  end

  private
    def manageable_record?
      product_membership_management_context? &&
        record.is_a?(ProductMembership) &&
        record.organization_id == Current.organization.id &&
        product_entitled?(record.product_id)
    end

    def active_target_membership?
      Current.organization.organization_memberships.active.exists?(
        id: record.organization_membership_id
      )
    end

    def active_product?
      Product.where(id: record.product_id, active: true).exists?
    end
end
