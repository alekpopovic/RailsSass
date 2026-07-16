class ProductRole < ApplicationRecord
  KEY_MAX_LENGTH = 63
  NAME_MAX_LENGTH = 100
  KEY_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

  belongs_to :product, inverse_of: :product_roles
  belongs_to :organization, optional: true, inverse_of: :product_roles
  has_many :product_role_permissions,
    dependent: :restrict_with_exception,
    inverse_of: :product_role
  has_many :product_permissions, through: :product_role_permissions
  has_many :product_membership_roles,
    dependent: :restrict_with_exception,
    inverse_of: :product_role
  has_many :product_memberships, through: :product_membership_roles

  normalizes :key, with: ->(key) { key.to_s.strip.downcase }
  normalizes :name, with: ->(name) { name.to_s.strip }

  attr_readonly :product_id, :organization_id, :key, :system

  validates :key,
    presence: true,
    length: { maximum: KEY_MAX_LENGTH },
    format: { with: KEY_PATTERN },
    uniqueness: { scope: [ :product_id, :organization_id ] }
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :system, :active, inclusion: { in: [ true, false ] }
  validate :system_scope_is_consistent

  private
    def system_scope_is_consistent
      return if (system? && organization_id.nil?) || (!system? && organization_id.present?)

      errors.add(:organization, "must be blank only for a system role")
    end
end
