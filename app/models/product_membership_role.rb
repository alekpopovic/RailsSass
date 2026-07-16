class ProductMembershipRole < ApplicationRecord
  belongs_to :organization, inverse_of: :product_membership_roles
  belongs_to :product, inverse_of: :product_membership_roles
  belongs_to :product_membership, inverse_of: :product_membership_roles
  belongs_to :product_role, inverse_of: :product_membership_roles

  before_validation :derive_membership_scope, on: :create

  attr_readonly :organization_id,
    :product_id,
    :product_membership_id,
    :product_role_id

  validates :product_role_id, uniqueness: { scope: :product_membership_id }
  validate :membership_scope_is_consistent
  validate :membership_accepts_new_role, on: :create
  validate :role_scope_is_assignable, on: :create

  private
    def derive_membership_scope
      self.organization ||= product_membership&.organization
      self.product ||= product_membership&.product
    end

    def membership_scope_is_consistent
      return if organization.blank? || product.blank? || product_membership.blank?
      return if product_membership.organization_id == organization.id &&
        product_membership.product_id == product.id

      errors.add(:product_membership, "must belong to the organization and product")
    end

    def role_scope_is_assignable
      return if product_role.blank? || organization.blank? || product.blank?

      errors.add(:product_role, "must be active") unless product_role.active?
      errors.add(:product_role, "must belong to the product") unless product_role.product_id == product.id

      role_organization_id = product_role.organization_id
      return if role_organization_id.nil? || role_organization_id == organization.id

      errors.add(:product_role, "must be a system role or belong to the organization")
    end

    def membership_accepts_new_role
      return if product_membership.blank?
      return if product_membership.active? && product_membership.organization_membership_status == "active"

      errors.add(:product_membership, "and its organization membership must be active")
    end
end
