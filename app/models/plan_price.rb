class PlanPrice < ApplicationRecord
  CURRENCY_PATTERN = /\A[A-Z]{3}\z/
  PROVIDER_ID_PATTERN = /\A\S+\z/
  PROVIDER_ID_MAX_LENGTH = 64

  belongs_to :plan, inverse_of: :plan_prices

  enum :billing_interval,
    { monthly: "monthly", yearly: "yearly" },
    validate: true

  normalizes :currency, with: ->(currency) { currency.to_s.strip.upcase }
  normalizes :lemon_store_id, :lemon_product_id, :lemon_variant_id,
    with: ->(identifier) { identifier.to_s.strip.presence }

  validates :currency,
    presence: true,
    length: { is: 3 },
    format: { with: CURRENCY_PATTERN }
  validates :amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :active, inclusion: { in: [ true, false ] }
  validates :lemon_store_id, :lemon_product_id, :lemon_variant_id,
    length: { maximum: PROVIDER_ID_MAX_LENGTH },
    format: { with: PROVIDER_ID_PATTERN },
    allow_nil: true
  validates :lemon_variant_id, uniqueness: true, allow_nil: true
  validate :lemon_mapping_is_complete

  private
    def lemon_mapping_is_complete
      identifiers = [ lemon_store_id, lemon_product_id, lemon_variant_id ]
      return if identifiers.all?(&:nil?) || identifiers.none?(&:nil?)

      errors.add(:lemon_variant_id, "must be provided with store and product IDs")
    end
end
