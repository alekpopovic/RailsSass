class ProductPermission < ApplicationRecord
  KEY_MAX_LENGTH = 100
  NAME_MAX_LENGTH = 100
  DESCRIPTION_MAX_LENGTH = 2_000
  KEY_SEGMENT = "[a-z][a-z0-9]*(?:_[a-z0-9]+)*".freeze
  KEY_PATTERN = /\A#{KEY_SEGMENT}(?:\.#{KEY_SEGMENT})+\z/

  belongs_to :product, inverse_of: :product_permissions
  has_many :product_role_permissions,
    dependent: :restrict_with_exception,
    inverse_of: :product_permission
  has_many :product_roles, through: :product_role_permissions

  normalizes :key, with: ->(key) { key.to_s.strip.downcase }
  normalizes :name, :description, with: ->(value) { value.to_s.strip }

  attr_readonly :product_id, :key

  validates :key,
    presence: true,
    length: { maximum: KEY_MAX_LENGTH },
    format: { with: KEY_PATTERN },
    uniqueness: { scope: :product_id }
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }
end
