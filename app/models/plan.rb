class Plan < ApplicationRecord
  KEY_MAX_LENGTH = 63
  NAME_MAX_LENGTH = 100
  DESCRIPTION_MAX_LENGTH = 2_000
  KEY_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

  has_many :plan_products,
    dependent: :restrict_with_exception,
    inverse_of: :plan
  has_many :products, through: :plan_products
  has_many :plan_feature_entitlements, through: :plan_products
  has_many :plan_prices,
    dependent: :restrict_with_exception,
    inverse_of: :plan

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
  validates :active, :free, inclusion: { in: [ true, false ] }
  validates :position,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :only_active_free_plan, if: -> { active? && free? }

  private
    def only_active_free_plan
      conflicting_plan = self.class.where(active: true, free: true).where.not(id: id)
      errors.add(:free, "already has an active plan") if conflicting_plan.exists?
    end
end
