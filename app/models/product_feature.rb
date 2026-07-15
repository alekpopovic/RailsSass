class ProductFeature < ApplicationRecord
  KEY_MAX_LENGTH = 63
  NAME_MAX_LENGTH = 100
  DESCRIPTION_MAX_LENGTH = 2_000
  KEY_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

  belongs_to :product, inverse_of: :product_features
  has_many :plan_feature_entitlements,
    dependent: :restrict_with_exception,
    inverse_of: :product_feature

  enum :kind,
    { flag: "flag", limit: "limit" },
    validate: true,
    scopes: false

  normalizes :key, with: ->(key) { key.to_s.strip.downcase }
  normalizes :name, :description, with: ->(value) { value.to_s.strip }

  attr_readonly :product_id, :key, :kind

  validates :key,
    presence: true,
    length: { maximum: KEY_MAX_LENGTH },
    format: { with: KEY_PATTERN },
    uniqueness: { scope: :product_id }
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }
  validates :active, inclusion: { in: [ true, false ] }
end
