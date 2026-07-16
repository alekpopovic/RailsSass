class ProductMembership < ApplicationRecord
  belongs_to :organization, inverse_of: :product_memberships
  belongs_to :organization_membership, inverse_of: :product_memberships
  belongs_to :product, inverse_of: :product_memberships
  has_many :product_membership_roles,
    dependent: :delete_all,
    inverse_of: :product_membership
  has_many :product_roles, through: :product_membership_roles

  enum :status, { active: "active", suspended: "suspended" },
    default: :active,
    validate: true

  before_validation :derive_organization, on: :create

  attr_readonly :organization_id,
    :organization_membership_id,
    :organization_membership_status,
    :product_id,
    :status

  validates :organization_membership_status, inclusion: { in: %w[active] }
  validates :product_id, uniqueness: { scope: :organization_membership_id }
  validate :organization_matches_membership
  validate :organization_membership_is_active
  validate :product_accepts_new_membership, on: :create

  private
    def derive_organization
      self.organization ||= organization_membership&.organization
      self.organization_membership_status ||= "active"
    end

    def organization_matches_membership
      return if organization.blank? || organization_membership.blank?
      return if organization_membership.organization_id == organization.id

      errors.add(:organization_membership, "must belong to the organization")
    end

    def organization_membership_is_active
      return if organization_membership.blank?
      return if organization_membership.active? && organization_membership_status == "active"

      errors.add(:organization_membership, "must be active")
    end

    def product_accepts_new_membership
      return if product.blank? || product.active?

      errors.add(:product, "must be active for a new membership")
    end
end
