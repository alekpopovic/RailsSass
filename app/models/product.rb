class Product < ApplicationRecord
  KEY_MAX_LENGTH = 63
  NAME_MAX_LENGTH = 100
  DESCRIPTION_MAX_LENGTH = 2_000
  KEY_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

  has_many :product_features,
    dependent: :restrict_with_exception,
    inverse_of: :product
  has_many :plan_products,
    dependent: :restrict_with_exception,
    inverse_of: :product
  has_many :plans, through: :plan_products
  has_many :plan_feature_entitlements,
    dependent: :restrict_with_exception,
    inverse_of: :product

  normalizes :key, with: ->(key) { key.to_s.strip.downcase }
  normalizes :name, :description, with: ->(value) { value.to_s.strip }

  attr_readonly :key

  validates :key,
    presence: true,
    length: { maximum: KEY_MAX_LENGTH },
    format: { with: KEY_PATTERN },
    uniqueness: true
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }
  validates :active, inclusion: { in: [ true, false ] }
end
